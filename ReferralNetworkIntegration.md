# Referral Network Integration Plan

Replace claim-time oracle fees with settlement-time referral network fees (`referralNetworkBps`), integrated with [referralTree](https://github.com/MagRelo/referralTree)'s `RewardDistributor`. At settlement, the fee is deducted from distributable TVL and atomically pushed up the **winning entry owner's referrer chain** — the winner is the lookup key only and is **not** a referral-fee recipient.

## Current vs Target Behavior

**Today:** [`ContestController.sol`](src/ContestController.sol) skims `oracleFeeBps` (5%) on every `claim*` / `push*` payout, accumulates it in `accumulatedOracleFee`, and the oracle withdraws via `claimOracleFee()`.

**Target:** Rename to `referralNetworkBps`, deduct the fee once at settlement from total distributable TVL, and distribute through referralTree when the winner has a real referrer; otherwise send the fee to `oracle`. Claims/pushes pay **full net amounts** with no further fee deduction.

```mermaid
sequenceDiagram
    participant Oracle
    participant Contest as ContestController
    participant Chain as ReferralGraph
    participant RD as RewardDistributor

    Oracle->>Oracle: Simulate settlement TVL; resolve winner and payoutAnchor
    Oracle->>Contest: settleContest(winners, payoutBps, rewardData, signature)
    Contest->>Contest: Compute referralFee from gross TVL
    Contest->>Contest: Scale primary payouts and secondary liquidity by netBps
    Contest->>Chain: getReferrer(winner, groupId) → payoutAnchor
    alt payoutAnchor is valid referrer
        Contest->>RD: safeTransfer(paymentToken, referralFee)
        Contest->>RD: distributeChainRewards(rewardData, signature)
        RD->>Chain: Walk chain upward from payoutAnchor
        RD->>RD: Geometric decay payout to referrers (winner excluded)
    else winner unregistered
        Contest->>Oracle: safeTransfer(paymentToken, referralFee)
    end
```

## Recommended Deployment Model (default)

Use a **single platform-wide deployment** configured on the factory:

| Component                          | Role                                                                  |
| ---------------------------------- | --------------------------------------------------------------------- |
| `ReferralGraph`                    | Shared referral tree (oracle registers users before/during contests)  |
| `RewardDistributor`                | Shared distributor; contest oracle must be authorized to sign rewards |
| `ContestFactory.rewardDistributor` | Immutable reference injected into every new contest                   |
| `ContestFactory.referralGroupId`   | Platform-wide `bytes32` (e.g. `keccak256("contest-catalyst-v1")`)     |

Rationale: referralTree is designed as shared infrastructure; one graph lets referrers earn across all contests. Per-contest `groupId` is possible later but adds registration complexity without clear benefit now.

## Core Contract Changes

### 1. Add referralTree dependency

```bash
forge install MagRelo/referralTree --no-commit
```

Add remapping in [`remappings.txt`](remappings.txt):

```
referralTree/=lib/referralTree/src/
```

Import interfaces only: `referralTree/interfaces/IRewardDistributor.sol` and `referralTree/interfaces/IReferralGraph.sol` (no need to vendor OpenZeppelin into contest contracts — we call `RewardDistributor`, we don't inherit it).

### 2. [`ContestFactory.sol`](src/ContestFactory.sol)

- Add immutable constructor params: `address rewardDistributor`, `bytes32 referralGroupId`
- Rename `createContest` arg `oracleFee` → `referralNetworkBps`
- Pass new params through to `ContestController` constructor

### 3. [`ContestController.sol`](src/ContestController.sol)

**Rename / replace storage:**

- `oracleFeeBps` → `referralNetworkBps` (same 1000 bps cap)
- Add immutables: `rewardDistributor`, `referralGroupId`
- Remove: `accumulatedOracleFee`, `claimOracleFee()`, `_calculateOracleFee()` usage in claim/push paths

**Extend `settleContest`:**

```solidity
function settleContest(
    uint256[] calldata winningEntries,
    uint256[] calldata payoutBps,
    IRewardDistributor.ChainRewardData calldata referralReward,
    bytes calldata referralSignature
) external onlyOracle nonReentrant
```

**Settlement fee logic (inside existing settle flow, after aggregating secondary TVL, before spill handling):**

1. Compute gross distributable TVL:
   - `totalPrimary = primaryPrizePool` (pre-allocation)
   - `totalSecondary = sum(secondaryLiquidityPerEntry + secondaryPrimarySubsidyPerEntry)` across active entries
   - `totalGross = totalPrimary + totalSecondary`
2. Compute fee: `referralFee = totalGross * referralNetworkBps / BPS_DENOMINATOR`
3. Apply net scaling uniformly: `netBps = BPS_DENOMINATOR - referralNetworkBps`
   - Primary payouts allocated from `totalPrimary * netBps / BPS_DENOMINATOR`
   - Winning entry secondary liquidity set to `totalSecondary * netBps / BPS_DENOMINATOR`
   - (Spill-to-primary path uses the already-net amounts)
4. If `referralFee > 0`:
   - Resolve winner: `winner = entryOwner[winningEntries[0]]` (must be non-zero)
   - Resolve payout anchor from referral graph:
     - `referralGraph = IRewardDistributor(rewardDistributor).getReferralGraph()`
     - `payoutAnchor = referralGraph.getReferrer(winner, referralGroupId)`
   - **If `payoutAnchor != address(0)` and `payoutAnchor != REFERRAL_ROOT`** (winner registered with a real referrer):
     - Validate `referralReward` matches on-chain computation:
       - `referralReward.totalAmount == referralFee`
       - `referralReward.user == payoutAnchor` (winner's immediate referrer, **not** the winner)
       - `referralReward.rewardToken == paymentToken`
       - `referralReward.groupId == referralGroupId`
       - `referralReward.timestamp == block.timestamp` (or `<= block.timestamp` with small tolerance — prefer exact match for simpler oracle signing)
     - `SafeTransferLib.safeTransfer(paymentToken, rewardDistributor, referralFee)`
     - `IRewardDistributor(rewardDistributor).distributeChainRewards(referralReward, referralSignature)`
   - **Else** (winner not registered, or referrer is `REFERRAL_ROOT` sentinel — no payable chain):
     - Skip `distributeChainRewards`; signature not required
     - `SafeTransferLib.safeTransfer(paymentToken, oracle, referralFee)` (fallback — mirrors old oracle-fee capture when no referral chain exists)
5. If `referralNetworkBps == 0`, skip step 4 entirely

**Remove fee logic from:** `claimPrimaryPayout`, `claimSecondaryPayout`, `pushPrimaryPayouts`, `pushSecondaryPayouts` — transfer full payout amounts.

**Secondary sweep edge case** (lines 289–296): remove `accumulatedOracleFee` guard; sweep only unallocated secondary dust.

**`closeContest`:** remove `accumulatedOracleFee = 0` (field deleted); keep sending remaining balance to `oracle` on expiry.

**New events:**

- `ReferralNetworkFeeDistributed(address indexed winner, address indexed payoutAnchor, uint256 amount, bytes32 eventId)` — emitted when fee is pushed through `RewardDistributor`
- `ReferralNetworkFeeToOracle(address indexed winner, uint256 amount)` — emitted when winner has no referrer and fee falls back to `oracle`

### 4. Referral chain anchor

referralTree's `ChainRewardData.user` is both the chain entry point **and** the first payout recipient (largest geometric-decay slice). The contest winner must **not** be set as `user` — they already receive primary/secondary winnings and must not double-dip on the referral fee.

**Lookup:** `winner = entryOwner[winningEntries[0]]`

**Payout anchor:** `ChainRewardData.user = ReferralGraph.getReferrer(winner, referralGroupId)`

referralTree then builds `[payoutAnchor, referrer(payoutAnchor), …]` and distributes the full `referralFee` across that chain. The winner is excluded from payouts.

| Winner registration | `payoutAnchor` | Outcome |
| ------------------- | -------------- | ------- |
| Registered with real referrer | winner's immediate referrer | Fee split across referrer chain; winner gets 0% of referral fee |
| Not registered | `address(0)` | No `distributeChainRewards`; full `referralFee` sent to `oracle` |
| Registered with `REFERRAL_ROOT` only | `REFERRAL_ROOT` (sentinel) | Same oracle fallback — sentinel is not a payable recipient |

## Oracle Off-Chain Signing Flow

Before calling `settleContest`, the oracle must:

1. Read on-chain pool state (`primaryPrizePool`, per-entry secondary balances)
2. Simulate the same gross/net math the contract will execute
3. Resolve winner and payout anchor:
   - `winner = entryOwner[winningEntries[0]]`
   - `payoutAnchor = ReferralGraph.getReferrer(winner, referralGroupId)`
4. If `payoutAnchor == address(0)` or `payoutAnchor == REFERRAL_ROOT`: call `settleContest` without signing (contract sends fee to `oracle`)
5. Else: build and sign `ChainRewardData`:
   - `user`: `payoutAnchor` (winner's referrer — **not** the winner)
   - `totalAmount`: computed `referralFee`
   - `rewardToken`: contest `paymentToken`
   - `groupId`: factory `referralGroupId`
   - `eventId`: unique per settlement (recommend `keccak256(abi.encodePacked(contestAddress, nonce))`)
   - `timestamp`: intended `block.timestamp` (oracle submits tx promptly)
   - `nonce`: monotonic per contest (pass via calldata; contract can store `referralSettlementNonce` to prevent replay)
6. Sign `keccak256(abi.encodePacked(user, totalAmount, rewardToken, groupId, eventId, timestamp, nonce))` with EIP-191 prefix (matching [`RewardDistributor.sol`](https://github.com/MagRelo/referralTree/blob/main/src/core/RewardDistributor.sol))

**Operational requirement:** authorize the contest oracle in both `ReferralGraph` (for user registration) and `RewardDistributor` (for reward signing).

## Test Plan

### New test helper (in test suite)

Deploy real `ReferralGraph` + `RewardDistributor` from the submodule in `setUp()`, authorize test oracle, register a small referral chain **for the winning entry owner** (so their referrer exists), and add a `_signReferralReward(payoutAnchor, ...)` helper using `vm.sign`.

### Update existing tests

Files to update (rename constants, remove claim-time fee assertions, add settlement signatures):

- [`test/ContestController.t.sol`](test/ContestController.t.sol) — largest surface; replace `ORACLE_FEE_BPS` → `REFERRAL_NETWORK_BPS`, remove `claimOracleFee` tests, update all `settleContest` calls
- [`test/ContestLifecycleE2E.t.sol`](test/ContestLifecycleE2E.t.sol)
- [`test/ContestBusyLifecycleE2E.t.sol`](test/ContestBusyLifecycleE2E.t.sol)
- [`test/SecondaryPricing.t.sol`](test/SecondaryPricing.t.sol) (constant rename only if referenced)

### New tests to add

- `test_settleContest_ReferralFeeDistributed` — verify RewardDistributor recipients (referrer chain only) receive geometric-decay amounts summing to `referralFee`; winner balance unchanged by referral fee
- `test_settleContest_ReferralFeeZeroSkipsDistribution` — `referralNetworkBps = 0`
- `test_settleContest_ReferralRewardMismatchReverts` — wrong `totalAmount`, wrong `user` (e.g. signed with winner instead of referrer), or stale signature
- `test_claimPrimaryPayout_NoFeeDeduction` — winner receives full net settlement amount
- `test_settleContest_UnregisteredWinner_FeeToOracle` — winner not in `ReferralGraph`; full `referralFee` sent to `oracle`, no `distributeChainRewards` call

### Docs / standards updates

- [`agents.md`](agents.md), [`SecondaryPricingBreakeven.md`](SecondaryPricingBreakeven.md), [`README.md`](README.md): rename `oracleFeeBps` → `referralNetworkBps`, document settlement-time referral push and oracle signing requirements

## Fee Economics (unchanged total)

With standard settings (`referralNetworkBps = 500`), total fee remains **5% of gross distributable TVL** at settlement. Because the fee is linear in gross amounts, this matches the sum of per-claim fees under the old model (modulo minor rounding differences from uniform net scaling vs per-claim rounding).

Example: 2 primary entries ($25 each, 7% subsidy) + $100 secondary → gross TVL ≈ $46.50 primary pool + secondary; referral fee ≈ 5% of total; winners claim 95% net.

## Risk / Edge Cases

| Case                                                | Handling                                                                 |
| --------------------------------------------------- | ------------------------------------------------------------------------ |
| `winningEntries[0]` has no entry owner              | Revert at settlement (invalid winner)                                    |
| Winner not registered in `ReferralGraph`            | `referralFee` sent to `oracle`; no signature or `distributeChainRewards` |
| Winner registered with `REFERRAL_ROOT` as referrer  | Same oracle fallback (`REFERRAL_ROOT` is not a payable recipient)        |
| Oracle signature stale (`timestamp` mismatch)       | Revert; oracle re-signs and retries                                      |
| `referralNetworkBps > 0`, referrer exists, but missing/invalid signature | Revert                              |
| `distributeChainRewards` reverts (double `eventId`) | Whole settlement reverts (atomic guarantee)                              |
| Contest cancelled / expired                         | No referral fee (unchanged — no settlement)                              |

## Out of Scope (follow-up)

- Automatic `ReferralGraph.register` on primary deposit (requires oracle/backend integration)
- Frontend / SDK for signing `ChainRewardData`
- Per-contest `groupId` or host-based lookup (winner still used only for `getReferrer` lookup, not as payout recipient)
- referralTree fork adding `excludeTriggerUserFromPayout` (not needed — referrer-as-`user` works with current API)

## Implementation Checklist

- [ ] Add referralTree forge dependency, remapping, and `IRewardDistributor` / `IReferralGraph` imports
- [ ] Update ContestFactory with rewardDistributor, referralGroupId, and referralNetworkBps param
- [ ] Refactor ContestController: settlement-time fee deduction; anchor `ChainRewardData.user` to winner's referrer; oracle fallback when unregistered; remove claim-time fees and claimOracleFee
- [ ] Add test harness: deploy ReferralGraph/RewardDistributor, referral chain setup, signing helper
- [ ] Update all existing tests and add referral distribution / revert coverage
- [ ] Update agents.md, README.md, SecondaryPricingBreakeven.md for referralNetworkBps and settlement flow
