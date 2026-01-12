# Secondary Market Pricing Guide

This document explains how the secondary market pricing works with the **Polynomial Bonding Curve** mechanism.

## Pricing Mechanism

The secondary market uses a **Polynomial Bonding Curve** pricing model:

**Price Formula**: `price = BASE_PRICE + COEFFICIENT * shares^2`

Where:

- `BASE_PRICE = 1e6` (1.0 minimum price, scaled by PRICE_PRECISION)
- `COEFFICIENT = 1` (controls curve steepness, scaled appropriately)
- `PRICE_PRECISION = 1e6` (represents 1.0)
- `shares` = current number of shares for this entry

### Implementation Details

The price calculation in code:

```solidity
uint256 sharesSquared = (shares / 1e9) * (shares / 1e9); // shares^2 scaled to avoid overflow
price = BASE_PRICE + (sharesSquared * COEFFICIENT) / 1e18;
```

The scaling factors (`/ 1e9` and `/ 1e18`) are used to prevent overflow when dealing with large share values (18 decimals).

### Key Properties

1. **Price Increases Quadratically with Shares**: As more shares are purchased, price increases quadratically (shares^2)
2. **Unbounded Growth**: Price can grow indefinitely as shares increase
3. **Early Bettor Advantage**: Lower shares = lower price = more tokens per dollar
4. **Whale Protection**: Large purchases cause dramatic price increases due to quadratic growth
5. **Simple and Gas Efficient**: Basic arithmetic operations, no complex calculations

## Price Behavior

### Quadratic Bonding Curve

The price follows a quadratic bonding curve:

- When shares = 0: `price = BASE_PRICE = 1.0`
- As shares increase: `price = BASE_PRICE + COEFFICIENT * shares^2`
- The quadratic term (`shares^2`) means price increases faster as shares increase

### Example Price Calculations

With `BASE_PRICE = 1e6` and `COEFFICIENT = 1`:

- **0 shares**: `price = 1e6 + (0^2 * 1) / 1e18 = 1,000,000` (1.0)
- **1e18 shares**: `price = 1e6 + ((1e18/1e9)^2 * 1) / 1e18 = 1e6 + 1 = 1,000,001` (≈ 1.0)
- **1e21 shares**: `price = 1e6 + ((1e21/1e9)^2 * 1) / 1e18 = 1e6 + 1e6 = 2,000,000` (2.0)
- **1e22 shares**: `price = 1e6 + ((1e22/1e9)^2 * 1) / 1e18 = 1e6 + 1e8 = 101,000,000` (101.0)

Note: The actual scaling in the implementation means the price increases very slowly for small share amounts, but accelerates dramatically as shares grow.

### Example Scenarios

#### Scenario 1: First Purchase on Entry

- Shares: 0
- Price: `1e6 + (0^2 * 1) / 1e18 = 1,000,000` (1.0)
- **Final price: 1.0**

#### Scenario 2: Small Purchase (1000 shares)

- Shares: 1000e18
- Price: `1e6 + ((1000e18/1e9)^2 * 1) / 1e18 = 1e6 + 1 = 1,000,001` (≈ 1.0)
- **Price remains near base price for small share amounts**

#### Scenario 3: Large Purchase (1e22 shares)

- Shares: 1e22
- Price: `1e6 + ((1e22/1e9)^2 * 1) / 1e18 = 1e6 + 1e8 = 101,000,000` (101.0)
- **Price increases dramatically with large share amounts**

#### Scenario 4: Whale Purchase (Price Increases)

- Before: 1e21 shares, price ≈ 2.0
- Whale buys tokens, increasing shares to 1e22
- After: 1e22 shares, price ≈ 101.0
- **Price increases significantly, protecting early buyers**

## Token Purchase Calculation

All purchases use the same method to ensure consistent and accurate pricing:

### Integrated Cost Calculation

For all purchases, we account for price movement during the purchase using Simpson's rule integration:

1. **Estimate tokens at current price**: `tokens_estimate = (payment * PRICE_PRECISION) / current_price`
2. **Binary search bounds**: `tokensLow = tokens_estimate / 2`, `tokensHigh = tokens_estimate * 2`
3. **Binary search**: Find tokens such that `integrated_cost(tokens) = payment`
4. **Simpson's rule**: `∫[a to b] f(x) dx ≈ (b-a)/6 * [f(a) + 4*f((a+b)/2) + f(b)]`

This ensures accurate pricing for all purchase sizes, accounting for price movement during the purchase. Even small purchases use this method for consistency and precision.

### Implementation Details

The binary search algorithm:

- Performs up to 50 iterations
- Stops when `tokensHigh <= tokensLow + 1`
- Uses Simpson's rule to calculate integrated cost at each step
- Returns `tokensLow` as the final token amount

The integrated cost calculation:

```solidity
sharesStart = sharesInitial
sharesEnd = sharesInitial + tokensToBuy
sharesMid = (sharesStart + sharesEnd) / 2

priceStart = calculatePrice(sharesStart)
priceMid = calculatePrice(sharesMid)
priceEnd = calculatePrice(sharesEnd)

delta = sharesEnd - sharesStart
sum = priceStart + (4 * priceMid) + priceEnd
cost = (delta * sum) / (6 * PRICE_PRECISION)
```

## Test Results

Run the tests to see actual behavior:

```bash
# Unit tests for pricing functions
forge test --match-path test/SecondaryPricing.t.sol -vv

# Integration tests with real scenarios
forge test --match-path test/SecondaryContestPricingSimulation.t.sol -vvv
```

### Simulation Test Results

The following tables show real-world simulation results from test runs with **current settings** (5% oracle fee, 5% position bonus, 30% target primary share, 15% max cross-subsidy). These demonstrate how the polynomial bonding curve behaves in practice.

#### Scenario 1: Sequential Equal Purchases

Three users each purchase $10 worth of shares on entry 1.

| User   | Purchase Size | Tokens Received | % of Total Shares | Price Before | Price After | Price Change | Price Per Share |
| ------ | ------------- | --------------- | ----------------- | ------------ | ----------- | ------------ | --------------- |
| User 1 | $10           | 9.0248e18       | 100.00%           | 1.0000       | 1.0001      | +0.00%       | 1.1081          |
| User 2 | $10           | 9.0233e18       | 50.00%            | 1.0001       | 1.0003      | +0.02%       | 1.1082          |
| User 3 | $10           | 9.0204e18       | 33.33%            | 1.0003       | 1.0007      | +0.04%       | 1.1086          |

**Observations:**

- First purchase gets the most tokens (100% of supply initially)
- Each subsequent purchase receives slightly fewer tokens as price increases
- Price increases gradually and smoothly for small equal purchases (0.00%, 0.02%, 0.04%)
- Price per share increases slightly with each purchase (1.1081 → 1.1082 → 1.1086), showing the bonding curve effect
- **With new settings**: More tokens per dollar (~9.02e18 vs ~4.95e18) due to more collateral per deposit

#### Scenario 2: Mixed Purchase Sizes

User 1 purchases $10, Whale purchases $1000, User 3 purchases $10.

| User   | Purchase Size | Tokens Received | % of Total Shares | Price Before | Price After | Price Change | Price Per Share |
| ------ | ------------- | --------------- | ----------------- | ------------ | ----------- | ------------ | --------------- |
| User 1 | $10           | 9.0248e18       | 100.00%           | 1.0000       | 1.0001      | +0.00%       | 1.1081          |
| Whale  | $1,000        | 6.6504e20       | 98.66%            | 1.0001       | 1.4544      | +45.42%      | 1.5037          |
| User 3 | $10           | 5.2618e18       | 0.78%             | 1.4544       | 1.4615      | +0.48%       | 1.9005          |

**Observations:**

- Whale purchase (100x larger) moves price significantly (+45.42%)
- Whale receives 73.7x more tokens than User 1 (less than 100x due to price movement during purchase)
- Small purchase after whale gets fewer tokens (5.26e18 vs 9.02e18) due to higher price
- Price per share increases dramatically for whale purchase (1.1081 → 1.5037), showing quadratic curve effect
- **With new settings**: More tokens per dollar for all purchases, but same qualitative behavior

#### Scenario 3: Multiple Entries Competition

Users purchase on different entries to show how prices evolve independently.

| Entry   | Purchases   | Final Price | Price Ratio vs Entry 2 |
| ------- | ----------- | ----------- | ---------------------- |
| Entry 1 | 3 purchases | 1.0007      | 1.0006x                |
| Entry 2 | 1 purchase  | 1.0001      | 1.0000x                |
| Entry 3 | 0 purchases | 1.0000      | 0.9999x                |

**Purchase Details for Entry 1:**

| User   | Purchase Size | Tokens Received | Price Before | Price After | Price Change | Price Per Share |
| ------ | ------------- | --------------- | ------------ | ----------- | ------------ | --------------- |
| User 1 | $10           | 9.0248e18       | 1.0000       | 1.0001      | +0.00%       | 1.1081          |
| User 2 | $10           | 9.0233e18       | 1.0001       | 1.0003      | +0.02%       | 1.1082          |
| User 4 | $10           | 9.0204e18       | 1.0003       | 1.0007      | +0.04%       | 1.1086          |

**Observations:**

- Each entry's price evolves independently based on its own supply
- Entry 1 with 3 purchases has higher price (1.0007) than Entry 2 with 1 purchase (1.0001)
- Price increases are gradual and smooth for small purchases
- Entry 1 is ~1.0006x more expensive than Entry 2, demonstrating independent price evolution

#### Scenario 4: Early vs Late Purchases

User 1 purchases early ($100), then many users purchase, then User 1 purchases again ($100).

| Purchase | Purchase Size | Tokens Received | Price Before | Price After | Price Change | Price Per Share |
| -------- | ------------- | --------------- | ------------ | ----------- | ------------ | --------------- |
| Early    | $100          | 9.0007e19       | 1.0000       | 1.0081      | +0.81%       | 1.1110          |
| Late     | $100          | 6.2268e19       | 1.2027       | 1.2626      | +4.98%       | 1.6060          |

**Observations:**

- Early purchase gets 44.5% more tokens than late purchase (9.00e19 vs 6.23e19)
- Price increased from 1.0000 to 1.2626 (26.26% increase) between purchases
- Early bettors receive better value: 1.111 vs 1.606 price per share (44.5% better for early)
- Price per share increases significantly for late purchase (1.111 → 1.606), showing strong early bettor advantage
- **With new settings**: More tokens overall, but same qualitative advantage for early buyers

#### Scenario 5: Whale Purchase Impact

Small purchases establish baseline, then whale makes massive purchase ($10,000).

| User   | Purchase Size | Tokens Received | % of Total Shares | Price Before | Price After | Price Change | Price Per Share |
| ------ | ------------- | --------------- | ----------------- | ------------ | ----------- | ------------ | --------------- |
| User 1 | $10           | 9.0248e18       | 33.33%            | 1.0000       | 1.0001      | +0.00%       | 1.1081          |
| User 2 | $10           | 9.0233e18       | 33.33%            | 1.0001       | 1.0003      | +0.02%       | 1.1082          |
| User 3 | $10           | 9.0204e18       | 33.33%            | 1.0003       | 1.0007      | +0.04%       | 1.1086          |
| Whale  | $10,000       | 3.8328e21       | 99.26%            | 1.0007       | 15.8987     | +1488.71%    | 2.6090          |
| User 4 | $10           | 4.8245e17       | 0.12%             | 15.8987      | 15.9025     | +0.02%       | 20.7275         |

**Observations:**

- First three small purchases show gradual price increases (0.00%, 0.02%, 0.04%) - smooth curve
- Whale purchase increases price dramatically by 1488.71% (from 1.0007 to 15.8987)
- Whale receives 424.7x more tokens than baseline users (spent 1000x more)
- Whale pays 2.35x more per share than baseline (2.609 vs 1.108) due to quadratic curve
- Small purchase after whale gets 18.7x fewer tokens (4.82e17 vs 9.02e18) due to massive price increase
- Price per share for User 4 is 18.7x higher than baseline (20.73 vs 1.108), showing strong whale protection
- **With new settings**: More dramatic price impact due to larger token amounts, demonstrating quadratic curve protection

#### Scenario 6: Early Buyers Maintain Share

Early buyers purchase, then whale makes large purchase.

| Buyer   | Purchase Size | Tokens Received | Share Before Whale | Share After Whale | Share Change | Price Per Share |
| ------- | ------------- | --------------- | ------------------ | ----------------- | ------------ | --------------- |
| Early 1 | $100          | 9.0007e19       | 53.8%              | 2.3%              | -51.5%       | 1.1110          |
| Early 2 | $100          | 7.7295e19       | 46.2%              | 2.0%              | -44.2%       | 1.2937          |
| Whale   | $10,000       | 3.7312e21       | -                  | 95.7%             | -            | 2.6801          |

**Price Changes:**

| Buyer   | Price Before | Price After | Price Change |
| ------- | ------------ | ----------- | ------------ |
| Early 1 | 1.0000       | 1.0081      | +0.81%       |
| Early 2 | 1.0081       | 1.0280      | +1.97%       |
| Whale   | 1.0280       | 16.1983     | +1475.72%    |

**Observations:**

- Early buyers' absolute token amounts remain unchanged
- Early buyers' percentage share decreases significantly (from ~54% and ~46% to ~2% each) due to whale's large purchase
- Whale purchase increases price by 1475.72%, dramatically affecting subsequent purchases
- Early buyers paid 1.111-1.294 per share, whale paid 2.680 per share (2.41x more)
- Early buyers maintain their absolute position but are diluted by whale's purchase
- **With new settings**: More tokens overall, but same dilution effect - early buyers maintain absolute position but lose percentage share

## Deposit Flow

When a secondary participant makes a deposit, the funds are allocated as follows:

1. **Oracle Fee**: 5% of deposit (500 basis points) - goes to oracle
2. **Position Bonus**: 5% of remaining amount (500 basis points) - goes to entry owner
3. **Cross-Subsidy**: Up to 15% of remaining amount (1500 basis points) - dynamically allocated to balance primary/secondary pools toward 30% target
4. **Collateral**: Remaining amount - backs ERC1155 tokens and determines pricing

**Example for $100 deposit:**

- Oracle fee: $5.00
- After fee: $95.00
- Position bonus: $4.75 (5% of $95)
- After bonus: $90.25
- Cross-subsidy: ~$13.54 (15% of $90.25, if needed to balance pools)
- Collateral: ~$76.71 (remaining amount used for token purchase)

The collateral amount is what actually goes into the bonding curve pricing calculation, meaning more tokens are received per dollar compared to previous settings with higher fees.

## Parameters

### Current Constants

| Parameter         | Value | Description                             |
| ----------------- | ----- | --------------------------------------- |
| `PRICE_PRECISION` | 1e6   | Represents 1.0 in price calculations    |
| `BASE_PRICE`      | 1e6   | Minimum price (1.0)                     |
| `COEFFICIENT`     | 1     | Coefficient for quadratic term (scaled) |

### Contest Settings

| Parameter               | Value | Description                                                 |
| ----------------------- | ----- | ----------------------------------------------------------- |
| `oracleFeeBps`          | 500   | Oracle fee: 5% (500 basis points)                           |
| `positionBonusShareBps` | 500   | Position bonus: 5% (500 basis points) - goes to entry owner |
| `targetPrimaryShareBps` | 3000  | Target primary-side share: 30% (3000 basis points)          |
| `maxCrossSubsidyBps`    | 1500  | Maximum cross-subsidy: 15% (1500 basis points)              |

### Tuning Parameters

If you need to adjust behavior:

1. **`COEFFICIENT`**: Controls curve steepness

   - Higher values: Steeper curve (price increases faster with shares)
   - Lower values: Flatter curve (price increases slower with shares)
   - Currently set to 1, scaled appropriately for shares^2
   - Note: The scaling factors in the implementation (`/ 1e9` and `/ 1e18`) affect how this coefficient behaves

2. **`BASE_PRICE`**: Controls minimum price
   - Higher values: Higher starting price
   - Lower values: Lower starting price
   - Currently set to 1e6 (1.0)

## Formula Reference

### Price Calculation Flow

```
1. Calculate sharesSquared = (shares / 1e9) * (shares / 1e9)
2. Calculate price = BASE_PRICE + (sharesSquared * COEFFICIENT) / 1e18
```

Where:

- `BASE_PRICE = 1e6` (1.0 minimum price)
- `COEFFICIENT = 1` (controls curve steepness)
- Price increases quadratically with shares: `price = BASE_PRICE + COEFFICIENT * shares^2`

### Tokens Minted

All purchases use the same calculation method:

```
tokens = binary_search such that integrated_cost(tokens) = collateral
```

Where `integrated_cost` uses Simpson's rule to account for price movement during purchase:

```
integrated_cost(shares_initial, tokens) = ∫[shares_initial to shares_initial + tokens] price(x) dx
```

Using Simpson's rule approximation:

```
cost ≈ (tokens / 6) * [price(shares_initial) + 4 * price(shares_initial + tokens/2) + price(shares_initial + tokens)]
```

This ensures consistent and accurate pricing for all purchase sizes, properly accounting for price movement during the purchase.

### Mathematical Formulation

For the quadratic bonding curve `price(x) = BASE_PRICE + COEFFICIENT * x^2`, the integrated cost from `shares_initial` to `shares_initial + tokens` is:

```
cost = ∫[s to s+t] (BASE_PRICE + COEFFICIENT * x^2) dx
     = BASE_PRICE * t + COEFFICIENT * ((s+t)^3 - s^3) / 3
```

However, the implementation uses Simpson's rule for numerical integration, which provides a good approximation and is more flexible if the price formula changes in the future.

## Comparison to Other Models

### Advantages over Constant Product

- ✅ **Price Increases Quadratically with Shares**: Price grows faster as demand increases
- ✅ **Whale Protection**: Large purchases cause significant price increases
- ✅ **Early Bettor Advantage**: Lower shares = much lower price
- ✅ **Unbounded**: Price can grow indefinitely
- ✅ **Simpler**: No need to maintain constant product invariant

### Advantages over LMSR

- ✅ **Simpler**: No complex exponential calculations
- ✅ **Gas Efficient**: Basic arithmetic operations (addition, multiplication, division)
- ✅ **More Intuitive**: Price directly relates to shares via quadratic formula
- ✅ **Deterministic**: Price depends only on shares, no external factors

### Advantages over Linear Bonding Curves

- ✅ **Better Whale Protection**: Quadratic growth means large purchases have exponentially more impact
- ✅ **Stronger Early Bettor Advantage**: Price difference between early and late buyers is more pronounced

## Notes

- All prices are scaled by `PRICE_PRECISION = 1,000,000` (1.0 = 1,000,000)
- Token amounts are in wei (18 decimals)
- Price increases quadratically with shares (`price = BASE_PRICE + COEFFICIENT * shares^2`), providing strong whale protection
- Early bettors get better prices (lower shares = lower price)
- The bonding curve ensures price increases as demand (shares) increases
- The scaling factors (`/ 1e9` and `/ 1e18`) in the implementation prevent overflow when dealing with large share values

## Migration Notes

### Settings Changes

The contest settings were updated from:

- **Old**: 1% oracle fee, 50% position bonus, 50% target primary share, 10% max cross-subsidy
- **New**: 5% oracle fee, 5% position bonus, 30% target primary share, 15% max cross-subsidy

### Impact on Pricing Behavior

1. **More Collateral Per Deposit**: With lower position bonus (5% vs 50%), more funds go to collateral, resulting in more tokens per dollar spent (~9.02e18 vs ~4.95e18 for $10 purchase)
2. **Slower Initial Price Growth**: More tokens per purchase means price increases more gradually for small purchases
3. **Same Core Properties**: The pricing algorithm (polynomial bonding curve) is unchanged, so all qualitative behaviors remain:
   - Early bettor advantage ✓
   - Whale protection ✓
   - Price increases with shares ✓
   - Quadratic growth for large purchases ✓

### Test Results

The test result tables in this document have been updated with current settings (as of latest test run). All values reflect the new settings:

- More tokens per dollar due to higher collateral allocation
- Same qualitative behaviors (early bettor advantage, whale protection)
- Price increases remain quadratic, providing strong protection against manipulation
