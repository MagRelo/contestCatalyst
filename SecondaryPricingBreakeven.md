# Break-Even Analysis: Secondary Market Pricing

## Contest Configuration

This analysis uses the following contest settings:

| Parameter                          | Value | Description                                                                 |
| ---------------------------------- | ----- | ----------------------------------------------------------------------------- |
| `PRIMARY_DEPOSIT`                  | $25   | Fixed amount each primary participant must deposit                            |
| `oracleFeeBps`                     | 500   | Oracle fee: 5% (500 basis points)                                               |
| `primaryDepositSecondarySubsidyBps`| 700   | 7% of each primary deposit credits `secondaryPrimarySubsidyPerEntry` (unbacked) |
| `COEFFICIENT`                      | 1     | Quadratic bonding curve coefficient                                           |
| `BASE_PRICE`                       | 1e6   | Minimum price: 1.0 (scaled by PRICE_PRECISION)                                  |
| `PRICE_PRECISION`                  | 1e6   | Price precision: 1.0 = 1,000,000                                              |

While the contest is open, each primary deposit splits: the carve sits in `secondaryPrimarySubsidyPerEntry[entryId]` and the remainder in `primaryPrizePool`. Secondary **buys** credit `secondaryLiquidityPerEntry` (backed; used for OPEN/CANCELLED sell-backs). At settlement, each entry’s backed + subsidy balances are merged into the winning primary entry’s id so holders redeem pro-rata against the combined secondary TVL.

## Overview

This document analyzes when additional betting on a single entry becomes economically prohibitive due to the quadratic bonding curve pricing mechanism with `COEFFICIENT = 1`.

**Note:** Numbers below follow `test/SecondaryPricingBreakeven.t.sol`. Re-run `forge test --match-path test/SecondaryPricingBreakeven.t.sol -vv` after changing contest parameters or curve constants and update this document if needed.

## Test Setup

- **Initial Configuration:**
  - **5 primary entries created** ($25 per entry → **$116.25** into `primaryPrizePool` and **$8.75** total into per-entry subsidy at 7% BPS)
  - **Each primary entry buys $20 secondary on their own entry**; each payment credits that entry’s `secondaryLiquidityPerEntry` and updates bonding-curve supply (settlement merge to the winning entry is outside this exercise)
  - **Primary `primaryPrizePool`** is unchanged when users add secondary positions
  - **Entry 1 initial state:** ~20.0 tokens on Entry 1, ~20% of global secondary supply (equal `$20` self-bets on each of the five entries; aggregate `getSecondarySideBalance` also includes **$8.75** primary subsidy)
  - **Two bettors alternate $10 purchases** on Entry 1, competing for ownership
  - Analysis tracks break-even economics for each bettor as they compete

## Key Findings

### Break-Even Points

**Bettor 1 reaches break-even at Purchase #11**, and **Bettor 2 reaches break-even at Purchase #12**.

- **Bettor 1 break-even:** Purchase #11, marginal value ≈$9.33, net value $0
- **Bettor 2 break-even:** Purchase #12, marginal value ≈$9.57, net value $0
- **Total wagered on Entry 1 at break-even:** $120 (initial $20 + $100 in competitive purchases; aggregate TVL includes the $8.75 bootstrap subsidy in `getSecondarySideBalance`)
- **Price at break-even:** ~1.017 (≈1.7% above base price)

**Key Insight:** With two bettors competing, ownership swings back and forth between them. Each bettor's purchases become less profitable as:

1. Prices rise due to the quadratic bonding curve
2. Ownership gains become smaller (already own significant share)
3. The other bettor's purchases reduce their relative ownership

Both bettors eventually reach break-even, demonstrating that competition doesn't prevent the economic limits of the bonding curve.

### Initial State

- **Primary prize pool:** **$116.25** from five `PRIMARY_DEPOSIT` payments while OPEN (93% of each deposit; oracle fee applies later on settled primary claims, not at deposit)
- **Aggregate secondary TVL (`getSecondarySideBalance`):** **$108.75** = $100 backed from five `$20` self-bets plus **$8.75** primary subsidy (each self-bet credits that entry’s `secondaryLiquidityPerEntry`; subsidy is per-entry and unbacked)
- **Entry 1 shares:** ~20.0 tokens after Entry 1’s `$20` self-bet (full payment priced on a single curve leg from zero supply)
- **Entry 1 ownership:** ~20% of **global** secondary supply across all entries at this point (equal `$20` bets on each of the five entries)

## Detailed Purchase Analysis

Tables below mix narrative rounding with outputs from `test/SecondaryPricingBreakeven.t.sol`. **Aggregate secondary TVL** after each `$10` buy increases by exactly `$10` (bootstrap yields **$108.75** starting TVL: $100 backed + $8.75 subsidy). Token counts, marginal value, and price columns should be re-checked with `forge test --match-path test/SecondaryPricingBreakeven.t.sol -vv` after any contract or parameter change.

### Competitive Purchases (Ownership Swings)

#### Purchase #1: Bettor 1 - $10

- **Cost:** $10
- **Tokens received:** ~9.99
- **Price before:** ~1.0004 (0.04% above base)
- **Price after:** ~1.0009 (0.09% above base)
- **Bettor 1 ownership:** 0% → 33.32%
- **Bettor 2 ownership:** 0% → 0%
- **Pot size (aggregate secondary TVL):** $108.75 → $118.75
- **Marginal value:** ~$36.65
- **Net value:** ~$26.65
- **Profitable:** ✅ YES

#### Purchase #2: Bettor 2 - $10

- **Cost:** $10
- **Tokens received:** ~9.99
- **Price before:** ~1.0009
- **Price after:** ~1.0016
- **Bettor 1 ownership:** 33.32% → 24.99% (decreases as Bettor 2 enters)
- **Bettor 2 ownership:** 0% → 24.98%
- **Pot size (aggregate secondary TVL):** $118.75 → $128.75
- **Marginal value:** ~$29.98
- **Net value:** ~$19.98
- **Profitable:** ✅ YES

**Key Observation:** Ownership swings back and forth. When Bettor 2 purchases, Bettor 1's ownership percentage decreases even though Bettor 1's absolute shares remain the same.

#### Purchase #10: Bettor 2 - $10

- **Cost:** $10
- **Tokens received:** ~9.87
- **Price before:** ~1.0120
- **Price after:** ~1.0143
- **Bettor 1 ownership:** 45.41% → 41.65% (decreases)
- **Bettor 2 ownership:** 36.34% → 41.61% (increases)
- **Pot size (aggregate secondary TVL):** $198.75 → $208.75
- **Marginal value:** ~$10.52
- **Net value:** ~$0.52
- **Profitable:** ✅ YES (barely profitable)

### Break-Even Points

#### Purchase #11: Bettor 1 - $10

- **Cost:** $10
- **Tokens received:** ~9.85
- **Price before:** ~1.0143
- **Price after:** ~1.0167 (≈1.67% above base)
- **Bettor 1 ownership:** 41.65% → 46.11% (increases)
- **Bettor 2 ownership:** 41.61% → 38.43% (decreases)
- **Pot size (aggregate secondary TVL):** $208.75 → $218.75
- **Marginal value:** ~$9.33
- **Net value:** $0
- **Profitable:** ❌ **NO - BETTOR 1 BREAK-EVEN POINT**

#### Purchase #12: Bettor 2 - $10

- **Cost:** $10
- **Tokens received:** ~9.82
- **Price before:** ~1.0167
- **Price after:** ~1.0193 (≈1.93% above base)
- **Bettor 1 ownership:** 46.11% → 42.84% (decreases)
- **Bettor 2 ownership:** 38.43% → 42.79% (increases)
- **Pot size (aggregate secondary TVL):** $218.75 → $228.75
- **Marginal value:** ~$9.57
- **Net value:** $0
- **Profitable:** ❌ **NO - BETTOR 2 BREAK-EVEN POINT**

**Analysis:** Both bettors reach break-even within one purchase of each other. The competitive dynamic causes ownership to swing back and forth, but rising prices and diminishing ownership gains eventually make further betting unprofitable for both. After break-even, both continue to lose value on each purchase.

### Unprofitable Purchases (Post Break-Even)

After both bettors reach break-even, all purchases show negative returns. Ownership continues to swing but with diminishing marginal value:

| Purchase # | Bettor | Marginal Value | Net Value | Bettor 1 %      | Bettor 2 %      | Price           |
| ---------- | ------ | -------------- | --------- | --------------- | --------------- | --------------- |
| #13        | 1      | $8.50          | -$1.50    | 42.84% → 46.61% | 42.79% → 39.97% | 1.0158 → 1.0181 |
| #14        | 2      | $8.69          | -$1.31    | 46.61% → 43.73% | 39.97% → 43.67% | 1.0181 → 1.0206 |
| #20        | 2      | $6.28          | -$3.72    | 47.51% → 45.68% | 42.06% → 44.92% | 1.0341 → 1.0369 |
| #30        | 2      | $5.20          | -$4.80    | 48.15% → 46.15% | 43.85% → 46.15% | 1.0665 → 1.0702 |
| #50        | 2      | $3.85          | -$6.15    | 47.50% → 47.50% | 47.50% → 47.50% | 1.1570 → 1.1623 |

**Key Insight:** Ownership swings back and forth between the two bettors, but both eventually reach break-even. The final ownership is nearly equal (~47% each), showing that competition doesn't prevent the economic limits - both bettors become unprofitable at similar points.

## Summary Statistics

### After 50 Purchases ($500 total wagering)

- **Total purchases analyzed:** 50
- **Total wagered on Entry 1:** $500
- **Final aggregate secondary TVL:** $608.75 (`$108.75` initial cross-entry liquidity + `$10` × 50 purchases credited to Entry 1)
- **Final Entry 1 shares:** ~482.5 tokens
- **Final bettor ownership:** ~95% combined for the two competing bettors (remainder on other entries’ bootstrap positions)

### Price Progression

- **Starting price:** ~1.0004 (0.04% above base price)
- **Price at break-even (Purchase #11-12):** ~1.014-1.019 (≈1.4-1.9% above base)
- **Final price (Purchase #50):** ~1.233 (≈23.3% above base)

The price increases from ~1.0004 to ~1.233 over 50 purchases, showing the quadratic bonding curve effect. Despite competitive ownership swings, prices rise steadily, eventually making further betting unprofitable for both bettors.

## Key Insights

### 1. Early Purchases Are Highly Profitable for Both Bettors

- Purchase #1 (Bettor 1): ~$26.65 net value (~267% return on $10)
- Purchase #2 (Bettor 2): ~$19.98 net value (~200% return)
- Purchase #3 (Bettor 1): ~$9.48 net value (~95% return)
- Both bettors benefit from early purchases, but returns diminish as competition intensifies

### 2. Ownership Swings Back and Forth

- **Purchase #1:** Bettor 1 gains 33.32% ownership
- **Purchase #2:** Bettor 1's ownership drops to 24.99% (Bettor 2 enters)
- **Purchase #3:** Bettor 1's ownership increases to 39.98%
- **Pattern:** Each purchase shifts ownership toward the purchasing bettor, but the other bettor's percentage decreases
- **Final state:** Both bettors end at ~47% ownership (nearly equal)

### 3. Both Bettors Reach Break-Even

- **Bettor 1 break-even:** Purchase #11 (marginal value ≈$9.33)
- **Bettor 2 break-even:** Purchase #12 (marginal value ≈$9.57)
- **Key insight:** Competition doesn't prevent break-even - both bettors become unprofitable within one purchase of each other
- **Reason:** Rising prices and diminishing ownership gains affect both bettors equally, regardless of who's ahead

### 4. How aggregate secondary TVL grows

- **Initial:** `$108.75` total across entries after five `$20` self-bets plus 7% primary subsidy (no transfers from `primaryPrizePool` during secondary trading).
- **Each `$10` competitive buy:** adds `$10` to Entry 1’s `secondaryLiquidityPerEntry` and therefore `$10` to `getSecondarySideBalance()` (other entries unchanged until someone trades there).
- **Ownership swings** reflect curve minting and competition on Entry 1 only.

### 5. COEFFICIENT Impact

With `COEFFICIENT = 1` and competitive betting (two bettors alternating):

- Break-even occurs at ~$120 **competitive** wagering on Entry 1 (initial $20 + $100; Purchases #11–12), with baseline aggregate TVL **$8.75** higher than the $100 backed-only case because of primary subsidy
- Price increases from ~1.0004x to ~1.014-1.019x at break-even
- Price increases to ~1.233x by Purchase #50
- **Critical factor:** Competition causes ownership to swing, but both bettors reach break-even at similar points. The quadratic bonding curve's price increases eventually make further betting unprofitable for both, regardless of competitive dynamics.

**If COEFFICIENT were higher:**

- Break-even would occur earlier (fewer purchases before becoming unprofitable)
- Prices would rise faster
- Less total wagering capacity on a single entry

**If COEFFICIENT were lower:**

- Break-even would occur later (more purchases remain profitable)
- Prices would rise slower
- More total wagering capacity on a single entry

## Competitive Dynamics

### Ownership Swings

With two bettors competing, ownership percentages swing back and forth:

- **Purchase #1 (Bettor 1):** Gains 33.32% ownership
- **Purchase #2 (Bettor 2):** Bettor 1's ownership drops to 24.99% (Bettor 2 enters)
- **Purchase #3 (Bettor 1):** Ownership increases to 39.98%
- **Purchase #4 (Bettor 2):** Bettor 1's ownership drops to 33.32%
- **Pattern continues:** Each purchase shifts ownership toward the purchasing bettor

### Why Both Bettors Reach Break-Even

Despite competitive swings, both bettors become unprofitable because:

1. **Rising prices:** The quadratic bonding curve causes prices to rise with each purchase
2. **Diminishing ownership gains:** As total shares increase, each purchase represents a smaller percentage increase
3. **Competitive pressure:** The other bettor's purchases reduce relative ownership, requiring more spending to maintain position
4. **Fees (at settlement):** Oracle fees apply when winners claim (`claim*` / `push*`), not as an upfront skim on each secondary payment during OPEN/ACTIVE

**Result:** Both bettors reach break-even within one purchase of each other, demonstrating that competition doesn't prevent the economic limits of the bonding curve.

## Economic Interpretation

### Why Break-Even Occurs

The break-even point occurs when:

```
Marginal Cost = Marginal Value
$10 = (Increase in Ownership %) × (Pot Size)
```

At Purchase #11 (Bettor 1 break-even):

- Cost: $10
- Ownership increase: ~4.5% (41.65% → 46.11%)
- Aggregate secondary TVL after trade: $210
- Marginal value: ~$9.33 (just below cost, making it break-even)

At Purchase #12 (Bettor 2 break-even):

- Cost: $10
- Ownership increase: ~4.4% (38.43% → 42.79%)
- Aggregate secondary TVL after trade: $220
- Marginal value: ~$9.57 (just below cost, making it break-even)

As more is wagered:

1. **Price increases** (quadratic curve) → fewer tokens per dollar
2. **Ownership % gains diminish** (diminishing marginal returns)
3. **Pot size increases** (but not enough to offset #1 and #2)

### Practical Implications

For competing bettors considering additional purchases:

1. **Early purchases (Purchases #1-10)** are profitable for both bettors
2. **Break-even points:** Bettor 1 at Purchase #11, Bettor 2 at Purchase #12
3. **All subsequent purchases (> Purchase #12)** destroy value for both because:
   - Ownership gains become smaller (both already own 40%+)
   - Prices rise due to quadratic curve
   - Marginal value drops below cost for both
   - Better ROI from betting on other entries

### Market Equilibrium

With competitive betting (two bettors alternating):

- **Maximum economically viable wagering:** ~$110–120 **per-entry competitive** spend on Entry 1 (10–12 purchases total, 5–6 per bettor), same competitive path as pre-subsidy baselines
- **Beyond this point:** Both bettors become unprofitable, regardless of who's ahead
- **Key insight:** Competition causes ownership swings, but doesn't prevent break-even. The bonding curve's price increases eventually make further betting unprofitable for all participants.
- **Final state:** Ownership stabilizes near 50/50, but both bettors are losing money on additional purchases
- **Liquidity:** Each competitive buy increases aggregate secondary TVL by the payment amount (`$108.75` → `$118.75` → … as `$10` purchases land on Entry 1).

## Secondary payment flow

On `addSecondaryPosition(entryId, amount)`:

1. The caller transfers **`amount`** payment token into the contest.
2. The full **`amount`** is credited to `secondaryLiquidityPerEntry[entryId]` (collateral for OPEN/CANCELLED sell-backs; merged at settlement).
3. **Minting:** `SecondaryPricing.calculateTokensFromCollateral` uses current nonnegative `netPosition[entryId]` as the starting supply; ERC1155 is minted to `msg.sender` for the computed amount.
4. **Oracle fees** apply on settled payout claims (`claim*` / `push*`), not on each secondary trade during OPEN/ACTIVE.

Secondary trades do not debit or credit `primaryPrizePool`; that pool changes on primary add/remove and on settlement payouts.

On `addPrimaryPosition`, **7%** of `PRIMARY_DEPOSIT` credits `secondaryPrimarySubsidyPerEntry[entryId]` and **93%** credits `primaryPrizePool` (standard `primaryDepositSecondarySubsidyBps = 700`).

## Conclusion

With `COEFFICIENT = 1`, `primaryDepositSecondarySubsidyBps = 700`, and competitive betting (two bettors alternating), the break-even points still occur at approximately **$120 total Entry-1 wagering** (initial $20 + $100 competitive; Purchases #11–12), while aggregate `getSecondarySideBalance` is **$8.75** higher throughout because of the primary subsidy carve. This means:

- ✅ **$20–110 Entry-1 wagering (Purchases #1–10):** Profitable for both bettors (returns taper from ~267% toward ~0%)
- ⚠️ **$120 Entry-1 wagering (Purchases #11–12):** Break-even points for both bettors (0% return)
- ❌ **$120+ Entry-1 wagering:** Unprofitable for both (negative returns, marginal value < cost)

**Critical Finding:** Competition causes ownership to swing back and forth, but both bettors reach break-even at similar points. The quadratic bonding curve's price increases eventually make further betting unprofitable for all participants, regardless of competitive dynamics. This demonstrates that competition doesn't prevent the economic limits of the bonding curve - fees and rising prices eventually make additional betting unprofitable for everyone.

The quadratic bonding curve effectively prevents excessive concentration of betting on a single entry, promoting a more balanced distribution across all entries in the contest.
