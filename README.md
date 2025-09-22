# DropVerse Smart Contract

A Clarity smart contract implementing a Merkle tree-based token airdrop system for the Stacks blockchain.

## Core Features

- **Airdrop Management**
  - Schedule token airdrops with specific time windows
  - Track claims per campaign
  - Prevent duplicate claims
  - Administrative controls

- **Token Distribution**
  - STX token distribution
  - Merkle proof verification
  - Automated claim processing

## Functions

### Administrative
- `schedule-airdrop`: Create new airdrop campaigns
- `fund-contract`: Fund contract with STX tokens

### User-Facing
- `claim`: Claim tokens from active airdrops
- `has-claimed`: Check if address has claimed
- `is-airdrop-active`: Verify airdrop status

### Read-Only
- `get-airdrop-info`: Retrieve campaign details
- `get-contract-balance`: View contract STX balance
- `get-total-claims`: Get total claims per campaign

## Data Storage

- Maps for storing airdrop campaign details
- Tracking claimed addresses
- Campaign parameters including:
  - Merkle root
  - Total tokens
  - Start/end blocks
  - Claim count

## Error Handling

Comprehensive error codes for:
- Authorization failures
- Timing violations
- Duplicate claims
- Invalid proofs
- Balance issues

## Notes

- Currently uses simplified Merkle proof verification
- Fixed claim amount of 1 STX (1,000,000 microSTX)
- Requires contract owner authorization for admin functions
