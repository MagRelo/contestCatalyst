# Secondary Pricing Parameter Tuning

**Status:** recommendation only — `src/SecondaryPricing.sol` constants are **unchanged** in this pass.

This document captures results from the Forge parameter sweep in [`test/SecondaryPricingTuning.t.sol`](test/SecondaryPricingTuning.t.sol). The sweep retunes the quadratic bonding curve so documented early-buyer advantage and whale friction engage in realistic contest sizes (audit Finding 11).

## How to run

```bash
forge test --match-path test/SecondaryPricingTuning.t.sol -vv
```

Requires maximum permissions in automated environments (see [`agents.md`](agents.md)).

## Formula (parameterized)

```
price = BASE_PRICE + ((shares / shareDivisor)^2 * coefficient) / COEFF_SCALE
```

| Constant         | Value | Notes                                      |
| ---------------- | ----- | ------------------------------------------ |
| `BASE_PRICE`     | 1e6   | Fixed (1.0)                                |
| `PRICE_PRECISION`| 1e6   | Fixed                                      |
| `COEFF_SCALE`    | 1e18  | Fixed                                      |
| `shareDivisor`   | swept | Production today: **1e9**                  |
| `coefficient`    | swept | Production: **15** (was 1 pre-tuning)          |

Mint path matches production: binary search + Simpson integration of the spot curve.

## Contest assumptions

Aligned with standard settings in [`agents.md`](agents.md) / [`SecondaryPricingBreakeven.md`](SecondaryPricingBreakeven.md):

- Payment token: 18 decimals (same as existing sims)
- `PURCHASE_INCREMENT = $10`
- Competitive breakeven report uses bootstrap pot **$108.75** (5× `$20` self-bets + 7% primary subsidy)

## Success thresholds

| Metric             | Scenario                                              | Pass if                                      |
| ------------------ | ----------------------------------------------------- | -------------------------------------------- |
| EarlyAdvantage     | `$10` at supply 0 vs `$10` after `$150` of `$10` buys | early/late tokens ≥ **1.25×**                |
| WhalePriceMove     | `$10`×3 then `$1000` whale                            | spot after whale ≥ **1.25×** pre-whale       |
| PostWhalePenalty   | `$10` after that whale                                | tokens ≤ **50%** of first `$10`              |
| CurveEngaged       | spot at `100e18` shares                               | ≥ **1.05×** `BASE_PRICE`                     |
| NotTooSteep        | first `$10` from zero                                 | tokens ≥ **7e18**                            |
| FrontRunCost       | `$5000` into empty entry                              | avg price paid ≥ **1.15×** base              |

Competitive **breakeven purchase #** (two bettors alternating `$10`) is reported but not a hard gate.

## Baseline (current production)

`shareDivisor = 1e9`, `coefficient = 15` (applied from the recommendation below)

| Metric           | Value        | Pass? |
| ---------------- | ------------ | ----- |
| EarlyAdvantage   | ~1.30×       | PASS  |
| WhalePriceMove   | ~5.04×       | PASS  |
| PostWhalePenalty | ~19.5% tokens| PASS  |
| CurveEngaged     | ~1.15× base  | PASS  |
| NotTooSteep      | ~10.00 tokens| PASS  |
| FrontRunCost     | avg ≥1.15×   | PASS  |
| **passCount**    | **6 / 6**    | —     |
| Breakeven #      | ~9           | (info)|

### Pre-tuning baseline (`coefficient = 1`)

| Metric           | Value        | Pass? |
| ---------------- | ------------ | ----- |
| EarlyAdvantage   | 1.024×       | FAIL  |
| WhalePriceMove   | 1.697×       | PASS  |
| PostWhalePenalty | 58.7% tokens | FAIL  |
| CurveEngaged     | 1.010× base  | FAIL  |
| NotTooSteep      | ~10.00 tokens| PASS  |
| FrontRunCost     | ~2.00× avg   | PASS  |
| **passCount**    | **3 / 6**    | —     |
| Breakeven #      | 11           | (info)|

Quadratic term barely engaged under `COEFFICIENT = 1` — audit Finding 11.

## Sweep summary

- Grid: 9 `shareDivisor` values × 17 `coefficient` values = **153** candidates
- **80** candidates pass all 6 metrics
- Ranking among all-pass prefers production `shareDivisor = 1e9`, then milder open (higher first-buy tokens), then later breakeven

## Recommended candidate

| Parameter      | Pre-tuning | Current production |
| -------------- | ---------- | ------------------ |
| `shareDivisor` | 1e9        | **1e9** (unchanged) |
| `coefficient`  | 1          | **15**             |

Applied in [`src/SecondaryPricing.sol`](src/SecondaryPricing.sol) as `COEFFICIENT = 15`.

### Recommended metrics

| Metric           | Value         | Pass? |
| ---------------- | ------------- | ----- |
| EarlyAdvantage   | 1.297×        | PASS  |
| WhalePriceMove   | 5.040×        | PASS  |
| PostWhalePenalty | 19.5% tokens  | PASS  |
| CurveEngaged     | 1.150× base   | PASS  |
| NotTooSteep      | ~9.995 tokens | PASS  |
| FrontRunCost     | ~2.00× avg    | PASS  |
| **passCount**    | **6 / 6**     | —     |
| Breakeven #      | 9             | (info)|

### Interpretation

- Early `$10` buyers get ~**30%** more tokens than a `$10` buy after `$150` volume (doc early-advantage goal).
- A `$1000` whale after three `$10` buys moves spot ~**5×**; the next `$10` gets ~**20%** of the tokens of the first buy (whale friction).
- Spot at `100e18` shares is **1.15×** base (curve clearly engaged).
- Competitive breakeven moves earlier (**purchase 11 → 9**): satisfying doc goals slightly shortens the profitable wagering window. Acceptable tradeoff; revisit if breakeven docs must stay at ~$120.

### Nearby all-pass (same divisor)

| coefficient | earlyAdv | whaleMove | postWhale | price@100 | breakeven # |
| ----------- | -------- | --------- | --------- | --------- | ----------- |
| **15** (rec)| 1.297×  | 5.04×     | 19.5%     | 1.15×     | 9           |
| 20          | 1.378×   | 6.32×     | 15.5%     | 1.20×     | 9           |
| 25          | 1.452×   | 7.56×     | 12.9%     | 1.25×     | 9           |
| 50          | 1.760×   | 13.4×     | 7.2%      | 1.50×     | 9           |
| 100         | 2.209×   | 23.0×     | 4.0%      | 2.00×     | 7           |

`coefficient = 12` (same divisor) does **not** clear EarlyAdvantage; **15** is the mildest production-divisor all-pass in this grid.

## Share units vs payment decimals

Secondary **ERC1155 share supply** and bonding-curve collateral inputs are always in **18-decimal share units** (`SecondaryPricing.SHARE_DECIMALS`), independent of `paymentToken.decimals()`.

`ContestController` stores `paymentTokenDecimals` at deploy and scales each secondary buy via `SecondaryPricing.toShareUnits(amount, paymentTokenDecimals)` before `calculateTokensFromCollateral`. Backed liquidity (`secondaryLiquidityPerEntry`) and ERC20 transfers stay in payment-token native decimals; sell-backs remain pro-rata `(shareAmount * liquidity) / supply`.

So a `$10` buy on 6-decimal USDC (`10e6`) mints the same share amount as a `$10` buy on an 18-decimal token (`10e18`).

## USDC / 6-decimal (resolved)

~~deferred normalize vs retune~~ — **normalized** via `toShareUnits` (see above). Curve constants including `COEFFICIENT = 15` apply unchanged to USDC contests.
