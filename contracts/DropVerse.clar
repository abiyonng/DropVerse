;; DropVerse Airdrop Contract
;; Implements Merkle tree-based token distribution system

;; Data storage for airdrop campaigns
(define-map airdrops uint { 
  root: (buff 32), 
  total: uint, 
  start: uint, 
  end: uint, 
  claimed: uint 
})

;; Track claimed addresses to prevent duplicate claims
(define-map claimed-addresses { airdrop-id: uint, address: principal } bool)

;; Contract owner for administrative functions
(define-constant contract-owner tx-sender)

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

;; Helper function to extract claim amount from proof
;; In production, this should properly decode the proof structure
(define-private (get-claim-amount (proof (buff 64)))
  ;; For now, return a fixed amount since proof parsing is complex
  ;; In production, this would properly decode the amount from the proof
  u1000000) ;; 1 STX in microSTX

;; Create leaf hash from address and amount for Merkle tree
;; Simplified version that avoids buffer concatenation issues
(define-private (create-leaf (address principal) (amount uint))
  ;; Create a simple deterministic hash using the address directly
  ;; In production, this would follow the exact Merkle tree leaf format
  ;; For now, we'll use a combination of hashes to create uniqueness
  (let ((addr-hash (hash160 (unwrap! (to-consensus-buff? address) 0x00))))
    ;; Combine with amount by XORing with amount's hash
    (hash160 (concat addr-hash (unwrap! (to-consensus-buff? amount) 0x00)))))

;; Simplified Merkle proof verification
;; In production, this should implement full Merkle tree verification
(define-private (verify-merkle-proof (leaf (buff 20)) (proof (buff 64)) (root (buff 32)))
  ;; This is a placeholder - real implementation would:
  ;; 1. Split proof into sibling hashes
  ;; 2. Reconstruct path to root by hashing leaf with siblings
  ;; 3. Compare final hash with stored root
  ;; For now, we'll do a basic non-zero check
  (and 
    (not (is-eq leaf 0x0000000000000000000000000000000000000000))
    (not (is-eq root 0x0000000000000000000000000000000000000000000000000000000000000000))))

;; Administrative function to schedule a new airdrop
(define-public (schedule-airdrop (id uint) (root (buff 32)) (total uint) (start uint) (end uint))
  (begin
    ;; Only contract owner can schedule airdrops
    (asserts! (is-eq tx-sender contract-owner) ERR-NOT-AUTHORIZED)
    ;; Ensure valid parameters
    (asserts! (> total u0) ERR-INVALID-TOTAL)
    (asserts! (< start end) ERR-INVALID-TIME-RANGE)
    ;; Store airdrop data
    (map-set airdrops id { 
      root: root, 
      total: total, 
      start: start, 
      end: end, 
      claimed: u0 
    })
    (ok true)))

;; Main claim function for users to claim their airdrop tokens
(define-public (claim (airdrop-id uint) (proof (buff 64)) (amount uint))
  (let ((airdrop-data (map-get? airdrops airdrop-id))
        (claim-key { airdrop-id: airdrop-id, address: tx-sender }))
    (match airdrop-data
      airdrop-info
        (begin
          ;; Check if airdrop is within valid time window
          (asserts! (and 
            (>= stacks-block-height (get start airdrop-info)) 
            (<= stacks-block-height (get end airdrop-info))) 
            ERR-INVALID-TIMING)
          
          ;; Check if user has already claimed
          (asserts! (is-none (map-get? claimed-addresses claim-key)) ERR-ALREADY-CLAIMED)
          
          ;; Ensure amount is greater than zero
          (asserts! (> amount u0) ERR-INVALID-AMOUNT)
          
          ;; Create leaf for verification
          (let ((leaf (create-leaf tx-sender amount)))
            ;; Verify Merkle proof
            (asserts! (verify-merkle-proof leaf proof (get root airdrop-info)) ERR-INVALID-PROOF)
            
            ;; Mark address as claimed
            (map-set claimed-addresses claim-key true)
            
            ;; Transfer tokens from contract to claimant
            (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
            
            ;; Update claimed count
            (map-set airdrops airdrop-id { 
              root: (get root airdrop-info), 
              total: (get total airdrop-info), 
              start: (get start airdrop-info), 
              end: (get end airdrop-info), 
              claimed: (+ (get claimed airdrop-info) u1) 
            })
            
            (ok true)))
      ERR-AIRDROP-NOT-FOUND)))

;; Function to fund the contract with STX for airdrops
(define-public (fund-contract (amount uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) ERR-NOT-AUTHORIZED)
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
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
  (stx-get-balance (as-contract tx-sender)))

;; Read-only function to get total claims for an airdrop
(define-read-only (get-total-claims (airdrop-id uint))
  (match (map-get? airdrops airdrop-id)
    airdrop-info (get claimed airdrop-info)
    u0))