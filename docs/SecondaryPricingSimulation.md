# Secondary Market Pricing Guide

## What this document is (and is not)

**Is:** Local mint-path / bonding-curve smell tests — how the per-entry quadratic curve mints tokens and moves spot price under scripted buys.

**Is not:** Settlement economics, claim EV, `P(win)` sizing, or market-design validation. Those live in [`SecondaryPricingBreakeven.md`](SecondaryPricingBreakeven.md). Curve parameter gates live in [`SecondaryPricingTuning.md`](SecondaryPricingTuning.md).

Secondary product worldview (for context only here): **pricing is local**, **redemption is global** (merged pot to `secondaryWinner`). These scenarios never settle.

## Pricing Mechanism

The secondary market uses a **Polynomial Bonding Curve**:

**Price Formula**: `price = BASE_PRICE + COEFFICIENT * shares^2`

Where:

- `BASE_PRICE = 1e6` (1.0 minimum price, scaled by PRICE_PRECISION)
- `COEFFICIENT = 15` (controls curve steepness; tuned via `SecondaryPricingTuning.md`)
- `PRICE_PRECISION = 1e6` (represents 1.0)
- `shares` = current number of shares for this entry

### Implementation Details

```solidity
uint256 sharesSquared = (shares / 1e9) * (shares / 1e9); // shares^2 scaled to avoid overflow
price = BASE_PRICE + (sharesSquared * COEFFICIENT) / 1e18;
```

### Key Properties (local curve)

1. **Price increases quadratically with shares**
2. **Unbounded growth** as shares increase
3. **Early / thin-entry advantage** — lower supply → more tokens per dollar
4. **Whale / late friction** — large purchases move price hard
5. **Gas-efficient** arithmetic (no LMSR exponentials)

These properties do **not** encode win probability.

## Token Purchase Calculation

All purchases use Simpson integration + binary search so cost accounts for price movement during the buy:

1. Estimate tokens at current price
2. Binary-search tokens such that `integrated_cost(tokens) = payment`
3. Simpson’s rule: `∫[a to b] f(x) dx ≈ (b-a)/6 * [f(a) + 4*f((a+b)/2) + f(b)]`

## How to run

```bash
forge test --match-path test/SecondaryPricingSimulation.t.sol -vv
# refresh tables:
forge test --match-path test/SecondaryPricingSimulation.t.sol -vvv
```

Use maximum permissions in automated environments (see [`agents.md`](../agents.md)). Keep scenario numbers aligned with the test file; refresh tables when curve constants change.

### Simulation Test Results

Standard settings: `referralNetworkBps = 500` (unused by mint-path scenarios), `primaryDepositSecondarySubsidyBps = 700`, `COEFFICIENT = 15`. Tables from a live `-vvv` run.

#### Scenario 1: Sequential Equal Purchases

Three users each purchase $10 on entry 1.

| User   | Purchase Size | Tokens Received | Price Before | Price After | Price Change | Price Per Share |
| ------ | ------------- | --------------- | ------------ | ----------- | ------------ | --------------- |
| User 1 | $10           | 9.9950e18       | 1.0000       | 1.0015      | +0.14%       | 1.0005          |
| User 2 | $10           | 9.9652e18       | 1.0015       | 1.0060      | +0.44%       | 1.0035          |
| User 3 | $10           | 9.9066e18       | 1.0060       | 1.0134      | +0.73%       | 1.0094          |

**Observations:** Each subsequent `$10` receives slightly fewer tokens; spot rises gradually for small equal buys.

#### Scenario 2: Mixed Purchase Sizes

User 1 `$10`, Whale `$1000`, User 3 `$10`.

| User   | Purchase Size | Tokens Received | Price Before | Price After | Price Change | Price Per Share |
| ------ | ------------- | --------------- | ------------ | ----------- | ------------ | --------------- |
| User 1 | $10           | 9.9950e18       | 1.0000       | 1.0015      | +0.14%       | 1.0005          |
| Whale  | $1,000        | 4.6481e20       | 1.0015       | 4.3816      | +337.50%     | 2.1514          |
| User 3 | $10           | 2.2739e18       | 4.3816       | 4.4140      | +0.74%       | 4.3978          |

**Observations:** `$1000` moves spot ~4.4×; post-whale `$10` gets ~23% of the tokens of the first `$10`.

#### Scenario 3: Multiple Entries Competition

| Entry   | Purchases   | Final Price |
| ------- | ----------- | ----------- |
| Entry 1 | 3 purchases | 1.0134      |
| Entry 2 | 1 purchase  | 1.0015      |
| Entry 3 | 0 purchases | 1.0000      |

**Observations:** Each entry’s price evolves from its own supply only.

#### Scenario 4: Early vs Late Purchases

| Purchase | Size | Tokens Received | Price Before | Price After | Price Per Share |
| -------- | ---- | --------------- | ------------ | ----------- | --------------- |
| Early    | $100 | 9.5628e19       | 1.0000       | 1.1372      | 1.0457          |
| Late     | $100 | 3.1782e19       | 2.9686       | 3.3292      | 3.1464          |

**Observations:** Early `$100` gets ~3.0× the tokens of a late `$100` after intervening volume; spot ~3.3× base by the late buy.

#### Scenario 5: Whale Purchase Impact

| User   | Purchase Size | Tokens Received | Price Before | Price After | Price Change | Price Per Share |
| ------ | ------------- | --------------- | ------------ | ----------- | ------------ | --------------- |
| User 1 | $10           | 9.9950e18       | 1.0000       | 1.0015      | +0.14%       | 1.0005          |
| User 2 | $10           | 9.9652e18       | 1.0015       | 1.0060      | +0.44%       | 1.0035          |
| User 3 | $10           | 9.9066e18       | 1.0060       | 1.0134      | +0.73%       | 1.0094          |
| Whale  | $10,000       | 1.1785e21       | 1.0134       | 22.9017     | +2159.93%    | 8.4855          |
| User 4 | $10           | 4.3650e17       | 22.9017      | 22.9175     | +0.06%       | 22.9096         |

**Observations:** `$10k` whale lifts spot ~22.6× vs pre-whale; post-whale `$10` gets ~22.9× fewer tokens than the first `$10`.

#### Scenario 6: Early Buyers Diluted in % Share

| Buyer   | Purchase Size | Tokens Received | Share Before Whale | Share After Whale | Price Per Share |
| ------- | ------------- | --------------- | ------------------ | ----------------- | --------------- |
| Early 1 | $100          | 9.5628e19       | ~55%               | ~8%               | 1.0457          |
| Early 2 | $100          | 7.8138e19       | ~45%               | ~6%               | 1.2798          |
| Whale   | $10,000       | 1.0420e21       | —                  | ~86%              | 9.5972          |

**Observations:** Absolute early tokens unchanged; % share dilutes when a whale mints into the same entry. That is supply dilution, not a settlement claim.

## Deposit Flow (mint path)

When a **primary** participant deposits, `primaryDepositSecondarySubsidyBps` (standard **700**) credits that entry’s `secondaryPrimarySubsidyPerEntry` and the remainder credits `primaryPrizePool` (no ERC1155 from the carve).

When a **secondary** participant pays `amount`:

1. **Minting:** `toShareUnits` then `calculateTokensFromCollateral` from current `netPosition`; ERC1155 to caller.
2. **Liquidity:** Full `amount` → `secondaryLiquidityPerEntry[entryId]` (OPEN/CANCELLED sell-back backing).

Settlement (loan repay, referral, merge to winner) is out of scope here — see Breakeven.

## Parameters

| Parameter         | Value | Description                             |
| ----------------- | ----- | --------------------------------------- |
| `PRICE_PRECISION` | 1e6   | Represents 1.0 in price calculations    |
| `BASE_PRICE`      | 1e6   | Minimum price (1.0)                     |
| `COEFFICIENT`     | 15    | Quadratic steepness (see Tuning doc)    |

| Parameter                        | Value | Description                                                                 |
| -------------------------------- | ----- | --------------------------------------------------------------------------- |
| `referralNetworkBps`             | 500   | Referral network fee at settlement (unused by these mint-path scenarios)    |
| `primaryDepositSecondarySubsidyBps` | 700 | 7% carve to per-entry subsidy on deposit                                    |

### Tuning knobs

1. **`COEFFICIENT`** (production **15**): higher → steeper curve / more whale friction; lower → flatter.
2. **`BASE_PRICE`**: minimum spot (1e6 = 1.0).

## Formula Reference

```
sharesSquared = (shares / 1e9) * (shares / 1e9)
price = BASE_PRICE + (sharesSquared * COEFFICIENT) / 1e18
tokens = binary_search such that integrated_cost(tokens) = collateral
```

Exact integral for `price(x) = BASE_PRICE + COEFFICIENT * x^2` exists; implementation uses Simpson for flexibility.

## Comparison to Other Models

- **Vs constant product / LMSR:** simpler gas, direct share→price map, unbounded quadratic whale friction.
- **Vs linear curve:** stronger late/whale cost growth.

None of these comparisons imply the curve discovers `P(win)` or balances secondary books across entries.

## Model summary

- **These sims:** local curve mint behavior only.
- **Product:** primary subsidy carve + secondary conviction market; settle merges residual secondary to winner after loan repay and referral. Size with `P(win)` — see Breakeven.

Re-run `forge test --match-path test/SecondaryPricingSimulation.t.sol -vv` to refresh tables after changing curve constants.
