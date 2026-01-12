# Break-Even Analysis: Secondary Market Pricing

## Contest Configuration

This analysis uses the following contest settings:

| Parameter               | Value | Description                                                 |
| ----------------------- | ----- | ----------------------------------------------------------- |
| `PRIMARY_DEPOSIT`       | $25   | Fixed amount each primary participant must deposit          |
| `oracleFeeBps`          | 500   | Oracle fee: 5% (500 basis points)                           |
| `positionBonusShareBps` | 500   | Position bonus: 5% (500 basis points) - goes to entry owner |
| `targetPrimaryShareBps` | 3000  | Target primary-side share: 30% (3000 basis points)          |
| `maxCrossSubsidyBps`    | 1500  | Maximum cross-subsidy: 15% (1500 basis points)              |
| `COEFFICIENT`           | 1     | Quadratic bonding curve coefficient                         |
| `BASE_PRICE`            | 1e6   | Minimum price: 1.0 (scaled by PRICE_PRECISION)              |
| `PRICE_PRECISION`       | 1e6   | Price precision: 1.0 = 1,000,000                            |

## Overview

This document analyzes when additional betting on a single entry becomes economically prohibitive due to the quadratic bonding curve pricing mechanism with `COEFFICIENT = 1`.

**Note:** This analysis is based on the current configuration with 5 primary entries ($125 total deposited, $118.75 in primary prize pool after 5% oracle fees), 30% target primary share, 5% oracle fee, and 15% maximum cross-subsidy. All results were generated from actual test runs.

## Test Setup

- **Initial Configuration:**
  - **5 primary entries created** ($25 per entry = $125 total deposited)
  - **Primary prize pool:** $118.75 (5 × $25 - 5% oracle fees = $125 - $6.25)
  - **Each primary entry bets $20 on themselves** ($20 × 5 = $100 total in secondary prize pool)
  - **Initial pool distribution:** Primary: $118.75, Secondary: $108.06 (after fees and cross-subsidies)
  - **Cross-subsidy behavior:** Subsidies flow to balance pools toward 30% primary target
  - **Entry 1 initial state:** 18.05 tokens, 20% ownership (equal bets on all 5 entries)
  - **Two bettors alternate $10 purchases** on Entry 1, competing for ownership
  - Analysis tracks break-even economics for each bettor as they compete

## Key Findings

### Break-Even Points

**Bettor 1 reaches break-even at Purchase #11**, and **Bettor 2 reaches break-even at Purchase #12**.

- **Bettor 1 break-even:** Purchase #11, marginal value $9.23, net value $0
- **Bettor 2 break-even:** Purchase #12, marginal value $9.43, net value $0
- **Total wagered on Entry 1 at break-even:** $120 (initial $20 + $100 in competitive purchases)
- **Price at break-even:** ~1.014 (1.4% above base price)

**Key Insight:** With two bettors competing, ownership swings back and forth between them. Each bettor's purchases become less profitable as:

1. Prices rise due to the quadratic bonding curve
2. Ownership gains become smaller (already own significant share)
3. The other bettor's purchases reduce their relative ownership

Both bettors eventually reach break-even, demonstrating that competition doesn't prevent the economic limits of the bonding curve.

### Initial State

- **Primary prize pool:** $118.75 (5 × $25 - 5% oracle fees = $125 - $6.25)
- **Secondary prize pool:** $108.06 (from $100 in bets + cross-subsidies)
- **Entry 1 shares:** 18.05 tokens (from initial $20 bet by Entry 1 owner)
- **Entry 1 ownership:** 20% (equal bets on all 5 entries: $20 each)
- **Primary share:** ~54% (above 30% target, so subsidies flow from primary to secondary)

## Detailed Purchase Analysis

### Competitive Purchases (Ownership Swings)

#### Purchase #1: Bettor 1 - $10

- **Cost:** $10
- **Tokens received:** 9.02
- **Price before:** 1.0003 (0.03% above base)
- **Price after:** 1.0007 (0.07% above base)
- **Bettor 1 ownership:** 0% → 33.32%
- **Bettor 2 ownership:** 0% → 0%
- **Pot size:** $108.06 → $117.09
- **Marginal value:** $39.02
- **Net value:** $29.02
- **Profitable:** ✅ YES

#### Purchase #2: Bettor 2 - $10

- **Cost:** $10
- **Tokens received:** 9.02
- **Price before:** 1.0007
- **Price after:** 1.0013
- **Bettor 1 ownership:** 33.32% → 24.99% (decreases as Bettor 2 enters)
- **Bettor 2 ownership:** 0% → 24.98%
- **Pot size:** $117.09 → $126.11
- **Marginal value:** $31.51
- **Net value:** $21.51
- **Profitable:** ✅ YES

**Key Observation:** Ownership swings back and forth. When Bettor 2 purchases, Bettor 1's ownership percentage decreases even though Bettor 1's absolute shares remain the same.

#### Purchase #10: Bettor 2 - $10

- **Cost:** $10
- **Tokens received:** 8.93
- **Price before:** 1.0098
- **Price after:** 1.0116
- **Bettor 1 ownership:** 45.41% → 41.65% (decreases)
- **Bettor 2 ownership:** 36.34% → 41.61% (increases)
- **Pot size:** $189.29 → $198.31
- **Marginal value:** $10.45
- **Net value:** $0.45
- **Profitable:** ✅ YES (barely profitable)

### Break-Even Points

#### Purchase #11: Bettor 1 - $10

- **Cost:** $10
- **Tokens received:** 8.91
- **Price before:** 1.0116
- **Price after:** 1.0136 (1.36% above base)
- **Bettor 1 ownership:** 41.65% → 46.11% (increases)
- **Bettor 2 ownership:** 41.61% → 38.43% (decreases)
- **Pot size:** $198.31 → $207.34
- **Marginal value:** $9.23
- **Net value:** $0
- **Profitable:** ❌ **NO - BETTOR 1 BREAK-EVEN POINT**

#### Purchase #12: Bettor 2 - $10

- **Cost:** $10
- **Tokens received:** 8.89
- **Price before:** 1.0136
- **Price after:** 1.0158 (1.58% above base)
- **Bettor 1 ownership:** 46.11% → 42.84% (decreases)
- **Bettor 2 ownership:** 38.43% → 42.79% (increases)
- **Pot size:** $207.34 → $216.36
- **Marginal value:** $9.43
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
- **Final secondary pot size:** $437.93
- **Final Entry 1 shares:** 398.95 tokens
- **Final bettor ownership:** 95% (increased from 0% to 95%)

### Price Progression

- **Starting price:** 1.0003 (0.03% above base price)
- **Price at break-even (Purchase #11-12):** 1.0136-1.0158 (1.36-1.58% above base)
- **Final price (Purchase #50):** 1.1623 (16.23% above base)

The price increases from ~1.0003 to ~1.1623 over 50 purchases, showing the quadratic bonding curve effect. Despite competitive ownership swings, prices rise steadily, eventually making further betting unprofitable for both bettors.

## Key Insights

### 1. Early Purchases Are Highly Profitable for Both Bettors

- Purchase #1 (Bettor 1): $29.02 net value (290% return)
- Purchase #2 (Bettor 2): $21.51 net value (215% return)
- Purchase #3 (Bettor 1): $10.25 net value (102% return)
- Both bettors benefit from early purchases, but returns diminish as competition intensifies

### 2. Ownership Swings Back and Forth

- **Purchase #1:** Bettor 1 gains 33.32% ownership
- **Purchase #2:** Bettor 1's ownership drops to 24.99% (Bettor 2 enters)
- **Purchase #3:** Bettor 1's ownership increases to 39.98%
- **Pattern:** Each purchase shifts ownership toward the purchasing bettor, but the other bettor's percentage decreases
- **Final state:** Both bettors end at ~47% ownership (nearly equal)

### 3. Both Bettors Reach Break-Even

- **Bettor 1 break-even:** Purchase #11 (marginal value $9.23)
- **Bettor 2 break-even:** Purchase #12 (marginal value $9.43)
- **Key insight:** Competition doesn't prevent break-even - both bettors become unprofitable within one purchase of each other
- **Reason:** Rising prices and diminishing ownership gains affect both bettors equally, regardless of who's ahead

### 4. Cross-Subsidy Effects Are Visible

- **Initial secondary pot:** $108.06 (from $100 bets + cross-subsidies from primary)
- **Subsidy flow:** Primary (54%) → Secondary (46%) to balance toward 30% target
- **Each purchase:** Pot grows, but ownership swings between bettors
- **Key insight:** Subsidies help bootstrap the market, but competition dynamics and bonding curve pricing determine break-even points

### 4. COEFFICIENT Impact

With `COEFFICIENT = 1` and competitive betting (two bettors alternating):

- Break-even occurs at ~$120 total wagering (initial $20 + $100 competitive = Purchases #11-12)
- Price increases from 1.0003x to 1.0136-1.0158x at break-even point
- Price increases to 1.16x by Purchase #50
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
4. **Fees and subsidies:** Oracle fees, position bonuses, and cross-subsidies reduce the effective value of each purchase

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
- Pot size: $207.34
- Marginal value: $9.23 (just below cost, making it break-even)

At Purchase #12 (Bettor 2 break-even):

- Cost: $10
- Ownership increase: ~4.4% (38.43% → 42.79%)
- Pot size: $216.36
- Marginal value: $9.43 (just below cost, making it break-even)

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

- **Maximum economically viable wagering:** ~$110-120 per entry (10-12 purchases total, 5-6 per bettor)
- **Beyond this point:** Both bettors become unprofitable, regardless of who's ahead
- **Key insight:** Competition causes ownership swings, but doesn't prevent break-even. The bonding curve's price increases eventually make further betting unprofitable for all participants.
- **Final state:** Ownership stabilizes near 50/50, but both bettors are losing money on additional purchases
- **Subsidy effect:** Cross-subsidies help bootstrap the market, but don't change break-even dynamics in competitive scenarios

## Payment Breakdown: Why Pot Size is Less Than Total Wagered

**Important Note:** The "pot size" shown in the analysis represents only the **collateral portion** that goes into the secondary prize pool, not the total amount wagered.

### Initial Pool Setup

Before secondary betting begins:

- **Primary prize pool:** $118.75 (5 × $25 - 5% oracle fees = $125 - $6.25)
- **Primary share:** 100% (no secondary bets yet)

After initial secondary bets (each entry bets $20 on themselves):

- **Primary prize pool:** $118.75 (5 × $25 - 5% oracle fees = $125 - $6.25, decreases as subsidies flow out)
- **Secondary prize pool:** $108.06 (from $100 in bets + cross-subsidies from primary)
- **Primary share:** ~54% (above 30% target, so subsidies flow from primary to secondary)
- **Each entry:** 20% ownership (equal $20 bets on all 5 entries)

### Cross-Subsidy Behavior

With `targetPrimaryShareBps = 30%`:

- **When primary share < 30%:** Cross-subsidies flow FROM secondary TO primary
- **When primary share > 30%:** Cross-subsidies flow FROM primary TO secondary
- **When primary share = 30%:** No cross-subsidies

In this analysis, since primary starts at 20% (below 30% target), cross-subsidies flow from secondary to primary to balance the pools.

### Payment Flow for Secondary Purchases

When a user makes a secondary purchase, the payment is split as follows:

1. **Oracle fee (5%)** → `accumulatedOracleFee` (goes to oracle)
2. **Position bonus (5% of amount after fee)** → `totalPrimaryPositionSubsidies` (goes to entry owner as reward for popularity)
3. **Cross-subsidy (variable, up to 15%)** → `primaryPrizePoolSubsidy` (goes to PRIMARY prize pool to balance pools toward 30% target)
4. **Collateral (remainder)** → `secondaryPrizePool` (goes to SECONDARY prize pool, backs the tokens)

**Example for a $10 purchase:**

- Oracle fee: $0.50 (5%)
- Amount after fee: $9.50
- Position bonus: $0.48 (5% of $9.50)
- Remaining: $9.02
- Cross-subsidy: ~$1.35 (up to 15% of remaining, variable based on pool balance toward 30% target)
- **Collateral: ~$7.67** (goes to secondary prize pool)

So only approximately **~77% of each payment** (after accounting for fees and subsidies) goes into the secondary prize pool that backs the tokens. This explains why:

- Total wagered: $725 ($125 primary + $100 initial secondary + $500 additional)
- Final secondary pot size: $514.64 (only the collateral portion)

The remaining funds are distributed to:

- Oracle fees: ~$36.25 (5% of $725)
- Position bonuses: ~$34.44 (5% of $688.75 after fees)
- Cross-subsidies: Variable (flows from primary to secondary to reach 30% target, visible in initial $108.06 pot being higher than $100 in bets)

## Conclusion

With `COEFFICIENT = 1` and competitive betting (two bettors alternating), the break-even points occur at approximately **$120 total wagering** on a single entry (initial $20 + $100 competitive). This means:

- ✅ **$20-110 wagering (Purchases #1-10):** Profitable for both bettors (returns ranging from 290% to 4%)
- ⚠️ **$120 wagering (Purchases #11-12):** Break-even points for both bettors (0% return)
- ❌ **$120+ wagering:** Unprofitable for both (negative returns, marginal value < cost)

**Critical Finding:** Competition causes ownership to swing back and forth, but both bettors reach break-even at similar points. The quadratic bonding curve's price increases eventually make further betting unprofitable for all participants, regardless of competitive dynamics. This demonstrates that competition doesn't prevent the economic limits of the bonding curve - fees and rising prices eventually make additional betting unprofitable for everyone.

The quadratic bonding curve effectively prevents excessive concentration of betting on a single entry, promoting a more balanced distribution across all entries in the contest.
