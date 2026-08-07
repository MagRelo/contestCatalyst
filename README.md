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
  - Manages primary prize pool and per-entry secondary liquidity; adding secondary positions does not move tokens into or out of the primary pool until settlement and claims
- **[PrimaryContest](src/PrimaryContest.sol)**: Library for primary mechanics (add/remove positions, claims)
- **[SecondaryContest](src/SecondaryContest.sol)**: Library for secondary mechanics (position management, ERC1155 operations)
- **[SecondaryPricing](src/SecondaryPricing.sol)**: Polynomial bonding curve (`price = BASE_PRICE + COEFFICIENT * shares²`); share supply is always 18-decimal units via `toShareUnits`, independent of payment-token decimals

### State Machine

```
OPEN → ACTIVE → LOCKED → SETTLED
  ↓      ↓        ↓
CANCELLED ←───────┘
```

- **OPEN**: Primary participants join/withdraw. Secondary market is **closed**.
- **ACTIVE**: Primary locked. Secondary buys open (non-transferable ERC1155 accounting shares).
- **LOCKED**: Secondary closed. Oracle may settle.
- **SETTLED**: Results in; users claim primary/secondary payouts (indefinitely — no privileged residual sweep).
- **CANCELLED**: Refunds via remove primary/secondary.
- **CLOSED**: Enum sentinel only; unreachable on-chain.

**Operational trust / expiry notes:**

- After `expiryTimestamp`, the oracle has an exclusive `SETTLEMENT_GRACE_PERIOD` (1 day) to `settleContest` while LOCKED. Permissionless `cancelExpired()` only unlocks after `expiryTimestamp + SETTLEMENT_GRACE_PERIOD` (lost-oracle / abandoned-contest escape hatch).
- Hot `oracle` settles, cancels, and pushes payouts. After push batches, any **unallocated** balance (integer-division residuals / donations with no claimable owner) is credited into the secondary winning pool, or else the first still-owed primary payout — never transferred to the oracle.
- There is no `emergencyRecoverFunds` path. Unclaimed SETTLED prizes remain claimable forever; CANCELLED deposits refund via `remove*`.
- Use a multisig for `oracle` in production. `paymentToken` should be a standard non-fee, non-rebasing ERC20 (#12).
- Contest operators must trust the `referralGraph` owner / per-group authorized oracles; a live `getReferrer` at settle is intentional (#8).

**Referral network fee:** At settlement, `referralNetworkBps` (≤10%) is deducted once from gross TVL. Distribution uses `ReferralGraph` + `RewardCalculator`; if the winner has no payable referrer or distribution fails, the fee is restored proportionally to the primary and secondary pools (never to the oracle). `claim*` / `push*` pay full net amounts.

## Quick Usage Guide

### Primary Participants

```solidity
// Add a position (must deposit exact primaryDepositAmount)
contest.addPrimaryPosition(entryId, merkleProof);

// Remove position during OPEN phase (full refund)
contest.removePrimaryPosition(entryId);

// After settlement: claim Layer-1 prize (net of referral fee applied at settlement)
contest.claimPrimaryPayout(entryId);
```

### Secondary Participants

```solidity
// Add position on an entry while ACTIVE (variable amount, non-transferable ERC1155)
contest.addSecondaryPosition(entryId, amount, merkleProof);

// Sell-back only while OPEN (pre-activate) or CANCELLED
contest.removeSecondaryPosition(entryId, tokenAmount);

// Claim payout after settlement (winning entry's ERC1155 holders, pro-rata)
contest.claimSecondaryPayout(entryId);
```

### Oracle Functions

```solidity
// State transitions
contest.activateContest();        // OPEN → ACTIVE
contest.lockContest();            // ACTIVE → LOCKED
contest.settleContest(winningEntries, payoutBps, secondaryWinner);  // LOCKED → SETTLED

// Optional: Push payouts for efficiency (full net amounts; allocates unallocated dust to winner pools)
contest.pushPrimaryPayouts(entryIds);
contest.pushSecondaryPayouts(participantAddresses, entryId);

// Other oracle functions
contest.setPrimaryMerkleRoot(root);
contest.setSecondaryMerkleRoot(root);
contest.cancelContest();
```

### View Functions

```solidity
// Pricing
uint256 price = contest.calculateSecondaryPrice(entryId);

// Balances
uint256 primaryBalance = contest.getPrimarySideBalance();
uint256 secondaryBalance = contest.getSecondarySideBalance(); // backed + primary subsidy per entry (see contract)

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
    paymentToken,                      // ERC20 token address (e.g., CUT)
    oracle,                            // Hot oracle (state, settle, push)
    contestantDepositAmount,           // Fixed deposit for primary participants
    referralNetworkBps,                // Referral network fee in basis points at settlement (max 1000 = 10%)
    expiry,                            // Expiration timestamp
    primaryDepositSecondarySubsidyBps, // e.g. 700 = 7%; BPS of each primary deposit to secondary subsidy (unbacked)
    referralGraph,                     // Platform ReferralGraph (referralTree)
    rewardCalculator,                  // Platform RewardCalculator (referralTree)
    referralGroupId                    // bytes32 group for ReferralGraph lookups
);
```

### Example Parameters

- `paymentToken`: Address of ERC20 token (typically platform token)
- `referralNetworkBps`: 500 = 5% fee at settlement (standard in tests)
- `referralGraph` / `rewardCalculator` / `referralGroupId`: per-contest immutables; backend typically passes the same platform values for every contest
- `primaryDepositSecondarySubsidyBps`: 700 = 7% (matches test and doc baselines in this repo)
- `expiry`: after this timestamp, oracle has `SETTLEMENT_GRACE_PERIOD` (1 day) exclusive settle window before permissionless `cancelExpired`

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
