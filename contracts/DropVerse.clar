;; DropVerse Airdrop Contract
;; Implements Merkle tree-based token distribution system

;; Data storage for airdrop campaigns
(define-map airdrops uint { 
  root: (buff 32), 
  total: uint, 
  start: uint, 
  end: uint, 
  claimed-count: uint,
  distributed: uint,
  finalized: bool 
})

;; Track claimed addresses to prevent duplicate claims
(define-map claimed-addresses { airdrop-id: uint, address: principal } bool)

;; Contract owner for administrative functions
(define-data-var contract-owner (optional principal) none)

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-TIMING (err u101))
(define-constant ERR-AIRDROP-NOT-FOUND (err u102))
(define-constant ERR-ALREADY-CLAIMED (err u103))
(define-constant ERR-INVALID-PROOF (err u104))
(define-constant ERR-INSUFFICIENT-BALANCE (err u105))
(define-constant ERR-INVALID-TOTAL (err u106))
(define-constant ERR-INVALID-TIME-RANGE (err u107))
(define-constant ERR-INVALID-AMOUNT (err u108))
(define-constant ERR-OWNER-NOT-SET (err u109))
(define-constant ERR-OWNER-ALREADY-SET (err u110))
(define-constant ERR-AIRDROP-EXISTS (err u111))
(define-constant ERR-AIRDROP-FINALIZED (err u112))
(define-constant ERR-AIRDROP-ACTIVE (err u113))
(define-constant ZERO-ROOT 0x0000000000000000000000000000000000000000000000000000000000000000)
(define-constant ZERO-LEAF ZERO-ROOT)

;; Helper to return the contract principal
(define-private (contract-self)
  (as-contract tx-sender))

;; Assert that the caller is the registered contract owner
(define-private (assert-contract-owner)
  (match (var-get contract-owner)
    owner-principal
      (if (is-eq tx-sender owner-principal)
          (ok true)
          ERR-NOT-AUTHORIZED)
      ERR-OWNER-NOT-SET))

;; Create leaf hash from address and amount for Merkle tree
(define-private (create-leaf (address principal) (amount uint))
  (let (
        (addr-hash (hash160 (unwrap! (to-consensus-buff? address) 0x00)))
        (amount-hash (sha256 (unwrap! (to-consensus-buff? amount) 0x00))))
    (sha256 (concat addr-hash amount-hash))))

;; Reduce a Merkle path to a root
(define-private (apply-sibling (segment (tuple (hash (buff 32)) (left bool))) (running (buff 32)))
  (let ((sibling (get hash segment)))
    (if (get left segment)
        (sha256 (concat sibling running))
        (sha256 (concat running sibling)))))

;; Simplified Merkle proof verification
;; Ensures proof length aligns with 32-byte sibling hashes
(define-private (verify-merkle-proof (leaf (buff 32)) (path (list 16 (tuple (hash (buff 32)) (left bool)))) (root (buff 32)))
  (let ((computed (fold apply-sibling path leaf)))
    (and
      (not (is-eq leaf ZERO-LEAF))
      (not (is-eq root ZERO-ROOT))
      (<= (len path) u16)
      (is-eq root computed))))

;; One-time owner initialization
(define-public (initialize-owner)
  (begin
    (asserts! (is-none (var-get contract-owner)) ERR-OWNER-ALREADY-SET)
    (var-set contract-owner (some tx-sender))
    (ok true)))

;; Administrative function to schedule a new airdrop
(define-public (schedule-airdrop (id uint) (root (buff 32)) (total uint) (start uint) (end uint))
  (begin
    ;; Only contract owner can schedule airdrops
    (try! (assert-contract-owner))
    ;; Ensure valid parameters
    (asserts! (> total u0) ERR-INVALID-TOTAL)
    (asserts! (< start end) ERR-INVALID-TIME-RANGE)
    (asserts! (is-none (map-get? airdrops id)) ERR-AIRDROP-EXISTS)
    ;; Store airdrop data
    (map-set airdrops id { 
      root: root, 
      total: total, 
      start: start, 
      end: end, 
      claimed-count: u0,
      distributed: u0,
      finalized: false 
    })
    (ok true)))

;; Main claim function for users to claim their airdrop tokens
(define-public (claim (airdrop-id uint) (proof (list 16 (tuple (hash (buff 32)) (left bool)))) (amount uint))
  (let ((recipient tx-sender)
        (airdrop-data (map-get? airdrops airdrop-id))
        (claim-key { airdrop-id: airdrop-id, address: recipient }))
    (match airdrop-data
      airdrop-info
        (begin
          ;; Check if airdrop is within valid time window
          (asserts! (and 
            (>= stacks-block-height (get start airdrop-info)) 
            (<= stacks-block-height (get end airdrop-info))) 
            ERR-INVALID-TIMING)
          
          ;; Ensure airdrop has not been finalized
          (asserts! (not (get finalized airdrop-info)) ERR-AIRDROP-FINALIZED)
          
          ;; Check if user has already claimed
          (asserts! (is-none (map-get? claimed-addresses claim-key)) ERR-ALREADY-CLAIMED)
          
          ;; Ensure amount is greater than zero
          (asserts! (> amount u0) ERR-INVALID-AMOUNT)

          (let ((leaf (create-leaf recipient amount))
                (new-distributed (+ (get distributed airdrop-info) amount))
                (contract-balance (stx-get-balance (contract-self))))
            ;; Verify Merkle proof
            (asserts! (verify-merkle-proof leaf proof (get root airdrop-info)) ERR-INVALID-PROOF)
            (asserts! (<= new-distributed (get total airdrop-info)) ERR-INSUFFICIENT-BALANCE)
            (asserts! (<= amount contract-balance) ERR-INSUFFICIENT-BALANCE)
            
            ;; Mark address as claimed
            (map-set claimed-addresses claim-key true)
            
            ;; Transfer tokens from contract to claimant
            (try! (as-contract (stx-transfer? amount tx-sender recipient)))
            
            ;; Update claimed metrics
            (map-set airdrops airdrop-id { 
              root: (get root airdrop-info), 
              total: (get total airdrop-info), 
              start: (get start airdrop-info), 
              end: (get end airdrop-info), 
              claimed-count: (+ (get claimed-count airdrop-info) u1),
              distributed: new-distributed,
              finalized: (get finalized airdrop-info) 
            })
            
            (ok true)))
      ERR-AIRDROP-NOT-FOUND)))

;; Finalize an airdrop after it ends and recover unclaimed STX
(define-public (finalize-airdrop (airdrop-id uint))
  (begin
    (try! (assert-contract-owner))
    (let ((owner tx-sender))
      (match (map-get? airdrops airdrop-id)
        airdrop-info
          (begin
            (asserts! (not (get finalized airdrop-info)) ERR-AIRDROP-FINALIZED)
            (asserts! (> stacks-block-height (get end airdrop-info)) ERR-AIRDROP-ACTIVE)
            (let ((unclaimed (- (get total airdrop-info) (get distributed airdrop-info))))
              (if (> unclaimed u0)
                  (try! (as-contract (stx-transfer? unclaimed tx-sender owner)))
                  true))
            (map-set airdrops airdrop-id { 
              root: (get root airdrop-info), 
              total: (get total airdrop-info), 
              start: (get start airdrop-info), 
              end: (get end airdrop-info), 
              claimed-count: (get claimed-count airdrop-info),
              distributed: (get distributed airdrop-info),
              finalized: true 
            })
            (ok true))
        ERR-AIRDROP-NOT-FOUND))))

;; Function to fund the contract with STX for airdrops
(define-public (fund-contract (amount uint))
  (begin
    (try! (assert-contract-owner))
    (try! (stx-transfer? amount tx-sender (contract-self)))
    (ok true)))

;; Read-only function to check if an address has claimed from an airdrop
(define-read-only (has-claimed (airdrop-id uint) (address principal))
  (is-some (map-get? claimed-addresses { airdrop-id: airdrop-id, address: address })))

;; Read-only function to get airdrop information
(define-read-only (get-airdrop-info (airdrop-id uint))
  (map-get? airdrops airdrop-id))

;; Read-only function to check if airdrop is currently active
(define-read-only (is-airdrop-active (airdrop-id uint))
  (match (map-get? airdrops airdrop-id)
    airdrop-info
      (and 
        (>= stacks-block-height (get start airdrop-info)) 
        (<= stacks-block-height (get end airdrop-info)))
    false))

;; Read-only function to get contract balance
(define-read-only (get-contract-balance)
  (stx-get-balance (contract-self)))

;; Read-only function to get total claims for an airdrop
(define-read-only (get-total-claims (airdrop-id uint))
  (match (map-get? airdrops airdrop-id)
    airdrop-info (get claimed-count airdrop-info)
    u0))
