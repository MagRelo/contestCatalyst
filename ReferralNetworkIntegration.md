# Referral Network Integration

Replace claim-time oracle fees with settlement-time referral network fees (`referralNetworkBps`), integrated with [referralTree](https://github.com/MagRelo/referralTree)'s `ReferralGraph` + `RewardCalculator`. At settlement, the fee is deducted from distributable TVL and atomically pushed up the **winning entry owner's referrer chain** — the winner is the lookup key only and is **not** a referral-fee recipient.

**Implemented:** [`ContestController.sol`](src/ContestController.sol) uses `referralNetworkBps` (5% standard), deducts the fee once at settlement from total distributable TVL, and pays the geometric split from contest balance when the winner has a real referrer; otherwise sends the fee to `oracle`. Claims/pushes pay **full net amounts** with no further fee deduction. Per-contest `referralGraph`, `rewardCalculator`, and `referralGroupId` are set on `createContest`.

## Flow

```mermaid
sequenceDiagram
    participant Oracle
    participant Contest as ContestController
    participant Graph as ReferralGraph
    participant Calc as RewardCalculator
    participant Token as ERC20

    Oracle->>Contest: settleContest(winners, payoutBps)
    Contest->>Contest: referralFee = grossTvl * referralNetworkBps / 10000
    Contest->>Graph: getReferrer(winner, groupId)
    alt no payable referrer
        Contest->>Token: transfer fee to oracle
    else has referrer
        Contest->>Graph: getPayoutChain(payoutAnchor, groupId, 10)
        Contest->>Calc: calculateRewards(fee, chain.length)
        loop each recipient
            Contest->>Token: safeTransfer(recipient, amount)
        end
    end
```

## Config

| Field | Notes |
| --- | --- |
| `ContestController.referralGraph` | Per-contest immutable |
| `ContestController.rewardCalculator` | Per-contest immutable |
| `ContestController.referralGroupId` | Per-contest immutable |
| `ContestController.referralNetworkBps` | Max 1000 (10%) |

Rationale: referralTree is shared attribution + split math. The contest owns custody and pays recipients directly during `settleContest` (already `onlyOracle`), so no signed `ChainRewardData` or escrow middleman is required.

## Settlement behavior

1. Compute `referralFee` from gross primary + secondary TVL.
2. Shrink primary/secondary pools by `netBps = 10000 - referralNetworkBps`.
3. If `referralFee > 0`:
   - `payoutAnchor = referralGraph.getReferrer(winner, referralGroupId)`
   - If no payable anchor (`address(0)` or `REFERRAL_ROOT`): transfer fee to `oracle`, emit `ReferralNetworkFeeToOracle`
   - Else `chain = getPayoutChain(payoutAnchor, …)` (skiplist-aware). If empty → fee to oracle.
   - Else `amounts = rewardCalculator.calculateRewards(referralFee, chain.length)`, transfer each amount from contest, emit `ReferralNetworkFeeDistributed(winner, payoutAnchor, fee, chain, amounts)`.

**Important:** Chain seed is the winner’s **immediate referrer**, not the winner. The winner already receives primary/secondary winnings and must not double-dip on the referral fee.

## Tests

[`ReferralTestHarness.sol`](test/helpers/ReferralTestHarness.sol) deploys real `ReferralGraph` + `RewardCalculator` and simplifies `_settleContest` to `settleContest(winners, payouts)`.

Key cases in [`ContestController.t.sol`](test/ContestController.t.sol):

- `test_settleContest_ReferralFeeDistributed` — referrer receives geometric amount; winner balance unchanged by fee
- `test_settleContest_ReferralFeeZeroSkipsDistribution` — `referralNetworkBps = 0`
- `test_settleContest_UnregisteredWinner_FeeToOracle` — full fee to oracle

## Indexing

- Payable chain: `ReferralNetworkFeeDistributed` on the contest (includes recipients + amounts)
- No chain: `ReferralNetworkFeeToOracle` on the contest
