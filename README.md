# Contest Catalyst

On-chain **contest escrow** plus a **conviction market** on the same entries. Used by [Play The Cut](https://github.com/MagRelo/cut). A trusted `operator` posts outcomes; the chain holds funds and enforces how they move.

## What it does

Two layers, one contest:

| Layer         | What it is        | How it works                                                                                                                                           |
| ------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Primary**   | Tournament Escrow | Users deposit a fixed amount. The operator computes tournament results off-chain, settles the escrow, and disburses the prize pool to named winners.   |
| **Secondary** | Conviction market | Users purchase shares in the outcome of the tournament. At settle, the total secondary-market TVL is distributed to share owners of the winning entry. |

**Pricing is local** (each entry’s own curve). **Redemption is global** (one merged pot for the winner). Size secondary as conviction — early/thin is cheaper on the curve; the curve does not discover win probability. Detail: [SecondaryPricingBreakeven.md](docs/SecondaryPricingBreakeven.md), [SecondaryPricingSimulation.md](docs/SecondaryPricingSimulation.md).

## Lifecycle

```
OPEN → ACTIVE → LOCKED → SETTLED
  ↓      ↓        ↓
CANCELLED
```

| State         | Primary Layer         | Secondary Layer                       |
| ------------- | --------------------- | ------------------------------------- |
| **OPEN**      | Join / withdraw       | Closed                                |
| **ACTIVE**    | Locked                | Buys open                             |
| **LOCKED**    | Locked                | Closed; operator may settle           |
| **SETTLED**   | Claim primary payouts | Winning-entry holders claim secondary |
| **CANCELLED** | Refund deposits       | Sell-back / refund positions          |

## Contract Structure

- **[ContestFactory](src/ContestFactory.sol)**: Factory for creating new contest instances
- **[ContestController](src/ContestController.sol)**: Main orchestrator contract managing both layers
  - Handles state transitions (`operator`-controlled)
  - Manages primary prize pool and per-entry secondary liquidity; adding secondary positions does not move tokens into or out of the primary pool until settlement and claims
- **[PrimaryContest](src/PrimaryContest.sol)**: Library for primary mechanics (add/remove positions, claims)
- **[SecondaryContest](src/SecondaryContest.sol)**: Library for secondary mechanics (position management, ERC1155 operations)
- **[SecondaryPricing](src/SecondaryPricing.sol)**: Polynomial bonding curve (`price = BASE_PRICE + COEFFICIENT * shares²`); share supply is always 18-decimal units via `toShareUnits`, independent of payment-token decimals

## Trust model: `operator` is a trusted escrow agent

`operator` is **not** an on-chain truth oracle. It is an immutable, trusted escrow/ops agent fixed on the factory (and copied into every contest). Participants must trust this address (prefer a multisig in production).

| Power        | Notes                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------- |
| Lifecycle    | `activateContest`, `lockContest`, `cancelContest`                                                       |
| Settlement   | Supplies `winningEntries`, `payoutBps`, and `secondaryWinner` with **no on-chain outcome verification** |
| Allowlists   | `setPrimaryMerkleRoot` / `setSecondaryMerkleRoot`                                                       |
| Push payouts | `pushPrimaryPayouts` / `pushSecondaryPayouts`                                                           |

This role is distinct from ReferralGraph’s per-group **authorized oracle** (referral-tree registration only).

## State Machine (ops notes)

Lifecycle summary is above. Extra rules:

- **CLOSED**: enum sentinel only; unreachable on-chain.

- After `expiryTimestamp`, the operator has an exclusive `SETTLEMENT_GRACE_PERIOD` (1 day) to `settleContest` while LOCKED. Permissionless `cancelExpired()` only unlocks after `expiryTimestamp + SETTLEMENT_GRACE_PERIOD` (lost-operator / abandoned-contest escape hatch).
- After push batches, any **unallocated** balance (integer-division residuals / donations with no claimable owner) is credited into the secondary winning pool, or else the first still-owed primary payout — never transferred to the operator.
- `paymentToken` should be a standard non-fee, non-rebasing ERC20.
- Participants must also trust the factory's immutable `referralGraph` owner / per-group authorized oracles; a live `getReferrer` at settle is intentional.

**Referral network fee:** At settlement, `referralNetworkBps` (≤10%) is deducted once from gross TVL. Distribution uses `ReferralGraph` + `RewardCalculator`; if the winner has no payable referrer or distribution fails, the fee is restored proportionally to the primary and secondary pools.

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

### Operator Functions (trusted escrow agent)

```solidity
// State transitions
contest.activateContest();        // OPEN → ACTIVE
contest.lockContest();            // ACTIVE → LOCKED
contest.settleContest(winningEntries, payoutBps, secondaryWinner);  // LOCKED → SETTLED

// Optional: Push payouts for efficiency (full net amounts; allocates unallocated dust to winner pools).
// Both primary and secondary batches isolate per-recipient failures (e.g. blocklisted addresses).
contest.pushPrimaryPayouts(entryIds);
contest.pushSecondaryPayouts(participantAddresses, entryId);

// Other operator functions
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
// Deploy factory once with platform trust surface (immutable for all contests from this factory)
ContestFactory factory = new ContestFactory(
    paymentToken,       // ERC20 token address (e.g., CUT)
    operator,           // Trusted escrow agent (lifecycle, settle, push) — prefer multisig
    referralGraph,
    rewardCalculator,
    referralGroupId
);

address contest = factory.createContest(
    contestantDepositAmount,           // Fixed deposit for primary participants
    referralNetworkBps,                // Referral network fee in basis points at settlement (max 1000 = 10%)
    expiry,                            // Expiration timestamp
    primaryDepositSecondarySubsidyBps  // e.g. 700 = 7%; deposit carve + settle loan-repay rate
);
```

### Example Parameters

- `paymentToken` / `operator` / `referralGraph` / `rewardCalculator` / `referralGroupId`: factory-level immutables set at factory deploy; every contest from that factory inherits them
- `operator`: trusted escrow/ops agent (not an on-chain truth oracle); use a multisig in production
- `referralNetworkBps`: 500 = 5% fee at settlement (standard in tests)
- `primaryDepositSecondarySubsidyBps`: 700 = 7% deposit carve and settle repay rate (matches test/doc baselines)
- `expiry`: after this timestamp, operator has `SETTLEMENT_GRACE_PERIOD` (1 day) exclusive settle window before permissionless `cancelExpired`

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
- **[SecondaryPricing.t.sol](test/SecondaryPricing.t.sol)**: Bonding curve unit tests
- **[SecondaryPricingSimulation.t.sol](test/SecondaryPricingSimulation.t.sol)**: Local mint-path curve smell tests (see docs)
- **[SecondaryPricingBreakeven.t.sol](test/SecondaryPricingBreakeven.t.sol)**: Settlement / claim-EV sims (sure-winner stress, `P(win)`, loser-float)
- **[SecondaryPricingTuning.t.sol](test/SecondaryPricingTuning.t.sol)**: Curve parameter sweep (Finding 11 gates)
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
