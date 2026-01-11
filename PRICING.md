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
forge test --match-path test/SecondaryContestPricing.t.sol -vvv
```

### Simulation Test Results

The following tables show real-world simulation results from the test scenarios. These demonstrate how the polynomial bonding curve behaves in practice.

#### Scenario 1: Sequential Equal Purchases

Three users each purchase $10 worth of shares on entry 1.

| User   | Purchase Size | Tokens Received | % of Total Shares | Price Before | Price After | Price Change | Price Per Share |
| ------ | ------------- | --------------- | ----------------- | ------------ | ----------- | ------------ | --------------- |
| User 1 | $10           | 4.9500e18       | 100.00%           | 1.0000       | 1.0000      | +0.00%       | 2.0202          |
| User 2 | $10           | 4.9497e18       | 50.00%            | 1.0000       | 1.0001      | +0.00%       | 2.0203          |
| User 3 | $10           | 4.9492e18       | 33.33%            | 1.0001       | 1.0002      | +0.01%       | 2.0205          |

**Observations:**

- First purchase gets the most tokens (100% of supply initially)
- Each subsequent purchase receives slightly fewer tokens as price increases
- Price increases gradually and smoothly for small equal purchases (0.00%, 0.00%, 0.01%)
- Price per share increases slightly with each purchase, showing the bonding curve effect

#### Scenario 2: Mixed Purchase Sizes

User 1 purchases $10, Whale purchases $1000, User 3 purchases $10.

| User   | Purchase Size | Tokens Received | % of Total Shares | Price Before | Price After | Price Change | Price Per Share |
| ------ | ------------- | --------------- | ----------------- | ------------ | ----------- | ------------ | --------------- |
| User 1 | $10           | 4.9500e18       | 100.00%           | 1.0000       | 1.0000      | +0.00%       | 2.0202          |
| Whale  | $1,000        | 4.1993e20       | 98.83%            | 1.0000       | 1.1805      | +18.05%      | 2.3813          |
| User 3 | $10           | 4.1867e18       | 0.98%             | 1.1805       | 1.1841      | +0.30%       | 2.3885          |

**Observations:**

- Whale purchase (100x larger) moves price significantly (+18.05%)
- Whale receives 84.8x more tokens than User 1 (less than 100x due to price movement during purchase)
- Small purchase after whale gets fewer tokens (4.19e18 vs 4.95e18) due to higher price
- Price per share increases dramatically for whale purchase, showing quadratic curve effect

#### Scenario 3: Multiple Entries Competition

Users purchase on different entries to show how prices evolve independently.

| Entry   | Purchases   | Final Price | Price Ratio vs Entry 2 |
| ------- | ----------- | ----------- | ---------------------- |
| Entry 1 | 3 purchases | 1.0002      | 1.00x                  |
| Entry 2 | 1 purchase  | 1.0000      | 1.00x                  |
| Entry 3 | 0 purchases | 1.0000      | 1.00x                  |

**Purchase Details for Entry 1:**

| User   | Purchase Size | Tokens Received | Price Before | Price After | Price Change | Price Per Share |
| ------ | ------------- | --------------- | ------------ | ----------- | ------------ | --------------- |
| User 1 | $10           | 4.9500e18       | 1.0000       | 1.0000      | +0.00%       | 2.0202          |
| User 2 | $10           | 4.9497e18       | 1.0000       | 1.0001      | +0.00%       | 2.0203          |
| User 4 | $10           | 4.9492e18       | 1.0001       | 1.0002      | +0.01%       | 2.0205          |

**Observations:**

- Each entry's price evolves independently based on its own supply
- Entry 1 with 3 purchases has slightly higher price (1.0002) than Entry 2 with 1 purchase (1.0000)
- Price increases are gradual and smooth for small purchases

#### Scenario 4: Early vs Late Purchases

User 1 purchases early ($100), then many users purchase, then User 1 purchases again ($100).

| Purchase | Purchase Size | Tokens Received | Price Before | Price After | Price Change | Price Per Share |
| -------- | ------------- | --------------- | ------------ | ----------- | ------------ | --------------- |
| Early    | $100          | 4.9460e19       | 1.0000       | 1.0024      | +0.24%       | 2.0218          |
| Late     | $100          | 4.5114e19       | 1.0835       | 1.1116      | +2.59%       | 2.2166          |

**Observations:**

- Early purchase gets 9.6% more tokens than late purchase (4.95e19 vs 4.51e19)
- Price increased from 1.0000 to 1.1116 (11.16% increase) between purchases
- Early bettors receive better value: 2.02 vs 2.22 price per share (9.6% higher for late)
- Price per share increases by 9.6% for late purchase, showing early bettor advantage

#### Scenario 5: Whale Purchase Impact

Small purchases establish baseline, then whale makes massive purchase ($10,000).

| User   | Purchase Size | Tokens Received | % of Total Shares | Price Before | Price After | Price Change | Price Per Share |
| ------ | ------------- | --------------- | ----------------- | ------------ | ----------- | ------------ | --------------- |
| User 1 | $10           | 4.9500e18       | 33.33%            | 1.0000       | 1.0000      | +0.00%       | 2.0202          |
| User 2 | $10           | 4.9497e18       | 33.33%            | 1.0000       | 1.0001      | +0.00%       | 2.0203          |
| User 3 | $10           | 4.9492e18       | 33.33%            | 1.0001       | 1.0002      | +0.01%       | 2.0205          |
| Whale  | $10,000       | 2.2270e21       | 99.01%            | 1.0002       | 6.0259      | +502.46%     | 4.4903          |
| User 4 | $10           | 8.2120e17       | 0.37%             | 6.0259       | 6.0296      | +0.06%       | 12.1773         |

**Observations:**

- First three small purchases show gradual price increases (0.00%, 0.00%, 0.01%) - smooth curve
- Whale purchase increases price dramatically by 502.46% (from 1.0002 to 6.0259)
- Whale receives 449.9x more tokens than baseline users (spent 1000x more)
- Whale pays 2.22x more per share than baseline (4.49 vs 2.02) due to quadratic curve
- Small purchase after whale gets 6.0x fewer tokens (8.21e17 vs 4.95e18) due to massive price increase
- Price per share for User 4 is 6.0x higher than baseline (12.18 vs 2.02), showing whale protection

#### Scenario 6: Early Buyers Maintain Share

Early buyers purchase, then whale makes large purchase.

| Buyer   | Purchase Size | Tokens Received | Share Before Whale | Share After Whale | Share Change | Price Per Share |
| ------- | ------------- | --------------- | ------------------ | ----------------- | ------------ | --------------- |
| Early 1 | $100          | 4.9460e19       | 50.1%              | 2.1%              | -48.0%       | 2.0218          |
| Early 2 | $100          | 4.9220e19       | 49.9%              | 2.1%              | -47.8%       | 2.0317          |
| Whale   | $10,000       | 2.2060e21       | -                  | 95.7%             | -            | 4.5331          |

**Price Changes:**

| Buyer   | Price Before | Price After | Price Change |
| ------- | ------------ | ----------- | ------------ |
| Early 1 | 1.0000       | 1.0024      | +0.24%       |
| Early 2 | 1.0024       | 1.0097      | +0.72%       |
| Whale   | 1.0097       | 6.3116      | +525.70%     |

**Observations:**

- Early buyers' absolute token amounts remain unchanged
- Early buyers' percentage share decreases significantly (from ~50% to ~2%) due to whale's large purchase
- Whale purchase increases price by 525.70%, dramatically affecting subsequent purchases
- Early buyers paid 2.02-2.03 per share, whale paid 4.53 per share (2.24x more)
- Early buyers maintain their absolute position but are diluted by whale's purchase

## Parameters

### Current Constants

| Parameter         | Value | Description                             |
| ----------------- | ----- | --------------------------------------- |
| `PRICE_PRECISION` | 1e6   | Represents 1.0 in price calculations    |
| `BASE_PRICE`      | 1e6   | Minimum price (1.0)                     |
| `COEFFICIENT`     | 1     | Coefficient for quadratic term (scaled) |

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
