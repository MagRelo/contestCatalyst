# Contest Catalyst

Combined competition format:

- **Tournament Contest:** a traditional competition format with established profitability
- **Prediction Market:** a betting mechanism layered on top of the tournament outcomes, also with proven profitability

Why? By combining and balancing incentives, the system achieves more than either component could independently:

<!-- Alternative options:
- Why? The combination creates synergistic value beyond what each layer offers independently:
- Why? Balancing & pooling incentives creates value greater than the sum of its parts:
- Why? The integration amplifies incentives, producing outcomes that exceed what either layer achieves alone:
- Why? By combining and balancing incentives, the system achieves more than either component could independently:
- Why? The interplay between layers creates emergent value that transcends their individual contributions:
  -->

- **Dynamic Incentives:** fluid movement of value between layers produces continuously changing incentives, sparking interest and driving activity
- **Positive Feedback**: both markets become more compelling as prize pools grow which attracts more participants and amplifies engagement

### Contract Structure

- **[ContestFactory](src/ContestFactory.sol)**: Factory for creating new contest instances
- **[ContestController](src/ContestController.sol)**: Main orchestrator contract managing both layers
  - Handles state transitions (oracle-controlled)
  - Manages prize pools and cross-subsidies
- **[PrimaryContest](src/PrimaryContest.sol)**: Library for primary mechanics (add/remove positions, claims)
- **[SecondaryContest](src/SecondaryContest.sol)**: Library for secondary mechanics (position management, ERC1155 operations)
- **[SecondaryPricing](src/SecondaryPricing.sol)**: Polynomial bonding curve pricing (`price = BASE_PRICE + COEFFICIENT * shares²`)

### State Machine

```
OPEN → ACTIVE → LOCKED → SETTLED → CLOSED
  ↓      ↓        ↓
CANCELLED ←───────┘
```

- **OPEN**: Primary participants join, secondary participants add positions, withdrawals allowed
- **ACTIVE**: Primary positions locked, secondary still open, no withdrawals
- **LOCKED**: Secondary positions closed
- **SETTLED**: Results in, users claim payouts
- **CANCELLED**: Contest cancelled, refunds available
- **CLOSED**: Force distributed

**Note on Cancellation & Expiry:**

- Anyone can call `cancelExpired()` if the contest has passed its expiry timestamp and is not `SETTLED` or `CLOSED`
- **In `CANCELLED` state**: Primary and secondary participants can withdraw their positions for full refunds (no deferred fees). No new positions can be added, and no payouts can be claimed.

## Quick Usage Guide

### Primary Participants

```solidity
// Add a position (must deposit exact primaryDepositAmount)
contest.addPrimaryPosition(entryId, merkleProof);

// Remove position during OPEN phase (full refund)
contest.removePrimaryPosition(entryId);

// Claim payout after settlement
contest.claimPrimaryPayout(entryId);
```

### Secondary Participants

```solidity
// Add position on an entry (variable amount, gets ERC1155 tokens)
contest.addSecondaryPosition(entryId, amount, merkleProof);

// Remove position during OPEN phase only (full refund)
contest.removeSecondaryPosition(entryId, tokenAmount);

// Claim payout after settlement (winner-take-all)
contest.claimSecondaryPayout(entryId);
```

### Oracle Functions

```solidity
// State transitions
contest.activateContest();        // OPEN → ACTIVE
contest.lockContest();            // ACTIVE → LOCKED
contest.settleContest(winningEntries, payoutBps);  // LOCKED → SETTLED

// Optional: Push payouts for efficiency
contest.pushPrimaryPayouts(entryIds);
contest.pushSecondaryPayouts(participantAddresses, entryId);

// Other oracle functions
contest.setPrimaryMerkleRoot(root);
contest.setSecondaryMerkleRoot(root);
contest.cancelContest();
contest.closeContest();
contest.claimOracleFee();
```

### View Functions

```solidity
// Pricing
uint256 price = contest.calculateSecondaryPrice(entryId);

// Balances
uint256 primaryBalance = contest.getPrimarySideBalance();
uint256 secondaryBalance = contest.getSecondarySideBalance();
uint256 shareBps = contest.getPrimarySideShareBps();  // Primary share as basis points

// Entry enumeration
uint256 count = contest.getEntriesCount();
uint256 entryId = contest.getEntryAtIndex(index);
```

## Deployment Guide

### 1. Deploy Factory

Deploy `ContestFactory` first:

```bash
forge script script/DeployFactory.s.sol:DeployFactoryScript \
  --rpc-url <your_rpc_url> \
  --private-key <your_private_key> \
  --broadcast
```

### 2. Create Contest

Use the factory to create a new contest:

```solidity
address contest = factory.createContest(
    paymentToken,           // ERC20 token address (e.g., CUT)
    oracle,                 // Oracle address (controls state)
    contestantDepositAmount, // Fixed deposit for primary participants
    oracleFee,              // Oracle fee in basis points (max 1000 = 10%)
    expiry,                 // Expiration timestamp
    positionBonusShareBps,  // Portion of subsidy to position bonuses (e.g., 5000 = 50%)
    targetPrimaryShareBps,  // Target primary share for cross-subsidy balancing
    maxCrossSubsidyBps      // Max cross-subsidy per deposit
);
```

### Example Parameters

- `paymentToken`: Address of ERC20 token (typically platform token)
- `oracleFee`: 100 = 1% fee
- `positionBonusShareBps`: 5000 = 50% of accumulated subsidy to bonuses
- `targetPrimaryShareBps`: 5000 = target 50/50 split between pools
- `maxCrossSubsidyBps`: 1000 = max 10% of deposit redirected

## Testing Guide

### Run All Tests

```bash
forge test
```

### Run Specific Test File

```bash
# Main integration tests
forge test --match-path test/ContestController.t.sol

# Pricing tests
forge test --match-path test/SecondaryPricing.t.sol

# Primary layer tests
forge test --match-path test/PrimaryContest.t.sol

# Secondary layer tests
forge test --match-path test/SecondaryContest.t.sol
```

### Test Coverage

```bash
forge coverage
```

### Gas Snapshots

```bash
forge snapshot
```

### Key Test Files

- **[ContestController.t.sol](test/ContestController.t.sol)**: Main integration tests covering both layers
- **[SecondaryPricing.t.sol](test/SecondaryPricing.t.sol)**: Bonding curve pricing tests
- **[PrimaryContest.t.sol](test/PrimaryContest.t.sol)**: Primary mechanics tests
- **[SecondaryContest.t.sol](test/SecondaryContest.t.sol)**: Secondary mechanics tests

## Development

### Build

```bash
forge build
```

### Format

```bash
forge fmt
```

### Local Node

```bash
anvil
```
