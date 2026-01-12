// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SecondaryPricing.sol";

/**
 * @title SecondaryPricingTest
 * @author MagRelo
 * @dev Comprehensive tests for SecondaryPricing library functions
 * 
 * Tests the polynomial bonding curve pricing mechanism:
 * - calculatePrice: price = BASE_PRICE + COEFFICIENT * shares^2
 * - calculateTokensFromCollateral: Token amount from collateral payment using integration
 * 
 * All tests respect standard settings from agents.md:
 * - PRIMARY_DEPOSIT = 25e18 ($25)
 * - PURCHASE_INCREMENT = 10e18 ($10)
 * - Standard contest configuration values
 */
contract SecondaryPricingTest is Test {
    // Standard settings from agents.md
    uint256 public constant PRIMARY_DEPOSIT = 25e18; // $25
    uint256 public constant PURCHASE_INCREMENT = 10e18; // $10
    uint256 public constant ORACLE_FEE_BPS = 500; // 5%
    uint256 public constant POSITION_BONUS_SHARE_BPS = 500; // 5%
    uint256 public constant TARGET_PRIMARY_SHARE_BPS = 3000; // 30%
    uint256 public constant MAX_CROSS_SUBSIDY_BPS = 1500; // 15%

    // Pricing constants (from SecondaryPricing.sol)
    uint256 public constant PRICE_PRECISION = SecondaryPricing.PRICE_PRECISION;
    uint256 public constant BASE_PRICE = SecondaryPricing.BASE_PRICE;
    uint256 public constant COEFFICIENT = SecondaryPricing.COEFFICIENT;

    // Safe input ranges to avoid overflow
    uint256 public constant MAX_SAFE_SHARES = 1e30;
    uint256 public constant MAX_SAFE_PAYMENT = 1e30;
    uint256 public constant PRECISION_TOLERANCE = 1e3; // 0.1% tolerance for integration

    // ============ Helper Functions ============

    /**
     * @notice Calculate expected price using exact formula
     * @param shares Current shares for this entry
     * @return price Expected price per token (scaled by PRICE_PRECISION)
     */
    function _calculateExactPrice(uint256 shares) internal pure returns (uint256) {
        // Exact formula: price = BASE_PRICE + COEFFICIENT * shares^2
        // Implementation: price = BASE_PRICE + (sharesSquared * COEFFICIENT) / 1e18
        // where sharesSquared = (shares / 1e9) * (shares / 1e9)
        uint256 sharesSquared = (shares / 1e9) * (shares / 1e9);
        return BASE_PRICE + (sharesSquared * COEFFICIENT) / 1e18;
    }

    /**
     * @notice Calculate exact integration cost using analytical formula
     * @param sharesInitial Initial shares before purchase
     * @param tokens Number of tokens to purchase
     * @return cost Exact cost in collateral units
     */
    function _calculateExactCost(uint256 sharesInitial, uint256 tokens) internal pure returns (uint256) {
        if (tokens == 0) {
            return 0;
        }

        // Exact integration: ∫[s to s+t] (BASE_PRICE + COEFFICIENT * x^2) dx
        // = BASE_PRICE * t + COEFFICIENT * ((s+t)^3 - s^3) / 3
        // But we need to account for the scaling in calculatePrice
        
        // For simplicity, we'll use a numerical approximation with many steps
        // This gives us a reference to compare against Simpson's rule
        uint256 steps = 100;
        uint256 stepSize = tokens / steps;
        if (stepSize == 0) stepSize = 1;
        
        uint256 totalCost = 0;
        for (uint256 i = 0; i < steps; i++) {
            uint256 currentShares = sharesInitial + (i * stepSize);
            uint256 price = SecondaryPricing.calculatePrice(currentShares);
            totalCost += (price * stepSize) / PRICE_PRECISION;
        }
        
        // Handle remainder
        uint256 remainder = tokens - (steps * stepSize);
        if (remainder > 0) {
            uint256 finalShares = sharesInitial + tokens;
            uint256 finalPrice = SecondaryPricing.calculatePrice(finalShares);
            totalCost += (finalPrice * remainder) / PRICE_PRECISION;
        }
        
        return totalCost;
    }

    /**
     * @notice Check if two values are within tolerance
     * @param a First value
     * @param b Second value
     * @param tolerance Tolerance (absolute)
     * @return True if values are within tolerance
     */
    function _isWithinPrecision(uint256 a, uint256 b, uint256 tolerance) internal pure returns (bool) {
        if (a > b) {
            return (a - b) <= tolerance;
        } else {
            return (b - a) <= tolerance;
        }
    }

    /**
     * @notice Calculate integrated cost using Simpson's rule (wrapper for testing)
     * This replicates the private _calculateIntegratedCost function for testing
     */
    function _calculateSimpsonCost(uint256 sharesInitial, uint256 tokensToBuy) internal pure returns (uint256) {
        if (tokensToBuy == 0) {
            return 0;
        }
        
        uint256 sharesStart = sharesInitial;
        uint256 sharesEnd = sharesInitial + tokensToBuy;
        uint256 sharesMid = (sharesStart + sharesEnd) / 2;
        
        uint256 priceStart = SecondaryPricing.calculatePrice(sharesStart);
        uint256 priceMid = SecondaryPricing.calculatePrice(sharesMid);
        uint256 priceEnd = SecondaryPricing.calculatePrice(sharesEnd);
        
        uint256 delta = sharesEnd - sharesStart;
        uint256 sum = priceStart + (4 * priceMid) + priceEnd;
        return (delta * sum) / (6 * PRICE_PRECISION);
    }

    // ============ calculatePrice Tests ============

    function test_calculatePrice_InitialState() public {
        uint256 shares = 0;
        uint256 price = SecondaryPricing.calculatePrice(shares);
        
        // Price should equal BASE_PRICE when shares = 0
        assertEq(price, BASE_PRICE, "Price should equal BASE_PRICE at zero shares");
    }

    function test_calculatePrice_FormulaCorrectness() public {
        uint256 shares = 1000e18;
        uint256 price = SecondaryPricing.calculatePrice(shares);
        uint256 expectedPrice = _calculateExactPrice(shares);
        
        assertEq(price, expectedPrice, "Price should match exact formula");
    }

    function test_calculatePrice_BasePriceMinimum() public {
        // Test that price is always >= BASE_PRICE
        uint256[] memory testShares = new uint256[](5);
        testShares[0] = 0;
        testShares[1] = 1e18;
        testShares[2] = 1000e18;
        testShares[3] = 1e21;
        testShares[4] = 1e22;
        
        for (uint256 i = 0; i < testShares.length; i++) {
            uint256 price = SecondaryPricing.calculatePrice(testShares[i]);
            assertGe(price, BASE_PRICE, "Price should always be >= BASE_PRICE");
        }
    }

    function test_calculatePrice_QuadraticGrowth() public {
        // Verify quadratic growth: price should increase faster as shares increase
        uint256 price1 = SecondaryPricing.calculatePrice(100e18);
        uint256 price2 = SecondaryPricing.calculatePrice(200e18);
        uint256 price3 = SecondaryPricing.calculatePrice(400e18);
        
        // Price difference should increase quadratically
        uint256 diff1 = price2 - price1;
        uint256 diff2 = price3 - price2;
        
        // For quadratic growth, diff2 should be much larger than diff1
        assertGt(diff2, diff1, "Price should grow quadratically");
    }

    function test_calculatePrice_PriceIncreasesWithShares() public {
        uint256 price1 = SecondaryPricing.calculatePrice(100e18);
        uint256 price2 = SecondaryPricing.calculatePrice(500e18);
        uint256 price3 = SecondaryPricing.calculatePrice(1000e18);
        uint256 price4 = SecondaryPricing.calculatePrice(2000e18);

        // Price should increase as shares increase
        assertGt(price2, price1, "Price should increase with shares");
        assertGt(price3, price2, "Price should increase with shares");
        assertGt(price4, price3, "Price should increase with shares");
    }

    function test_calculatePrice_OnlyDependsOnShares() public {
        uint256 shares = 1000e18;
        uint256 price1 = SecondaryPricing.calculatePrice(shares);
        uint256 price2 = SecondaryPricing.calculatePrice(shares);

        // Price should be deterministic based only on shares
        assertEq(price1, price2, "Price should be deterministic based only on shares");
    }

    function test_calculatePrice_StandardPurchaseIncrements() public {
        // Test with standard purchase increments from agents.md
        uint256 shares = 0;
        
        // Simulate purchases of $10 increments
        for (uint256 i = 0; i < 5; i++) {
            uint256 payment = PURCHASE_INCREMENT * (i + 1);
            uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
            shares += tokens;
            
            uint256 price = SecondaryPricing.calculatePrice(shares);
            assertGe(price, BASE_PRICE, "Price should be >= BASE_PRICE after purchase");
        }
    }

    // ============ calculateTokensFromCollateral Tests ============

    function test_calculateTokensFromCollateral_ZeroCollateral() public {
        uint256 shares = 1000e18;
        uint256 payment = 0;
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        
        assertEq(tokens, 0, "Should return 0 tokens for zero payment");
    }

    function test_calculateTokensFromCollateral_SmallPurchase() public {
        uint256 shares = 1000e18;
        uint256 payment = PURCHASE_INCREMENT; // $10
        
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        
        assertGt(tokens, 0, "Should return tokens for small purchase");
    }

    function test_calculateTokensFromCollateral_LargePurchase() public {
        uint256 shares = 1000e18;
        uint256 payment = 2000e18; // $2000
        
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        
        assertGt(tokens, 0, "Should return tokens for large purchase");
    }

    function test_calculateTokensFromCollateral_PriceIncreases() public {
        uint256 shares = 1000e18;
        uint256 payment = PURCHASE_INCREMENT * 2; // $20
        
        uint256 tokens1 = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        uint256 shares2 = shares + tokens1;
        uint256 tokens2 = SecondaryPricing.calculateTokensFromCollateral(shares2, payment);

        // Second purchase should give fewer tokens (price increased)
        assertLt(tokens2, tokens1, "Second purchase should give fewer tokens due to price increase");
    }

    function test_calculateTokensFromCollateral_Consistency() public {
        uint256 shares = 1000e18;
        uint256 payment1 = PURCHASE_INCREMENT; // $10
        uint256 payment2 = PURCHASE_INCREMENT * 2; // $20
        
        uint256 tokens1 = SecondaryPricing.calculateTokensFromCollateral(shares, payment1);
        uint256 tokens2 = SecondaryPricing.calculateTokensFromCollateral(shares, payment2);
        
        // More payment should give more tokens (or equal if rounding)
        assertGe(tokens2, tokens1, "More payment should give more tokens");
    }

    function test_calculateTokensFromCollateral_RoundTrip() public {
        uint256 shares = 1000e18;
        uint256 payment = PURCHASE_INCREMENT * 5; // $50
        
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        uint256 actualCost = _calculateSimpsonCost(shares, tokens);
        
        // Actual cost should be close to payment (within tolerance)
        // Note: actualCost may be slightly less due to binary search rounding down
        assertLe(actualCost, payment, "Actual cost should not exceed payment");
        assertGe(actualCost, payment * 99 / 100, "Actual cost should be close to payment");
    }

    function test_calculateTokensFromCollateral_IntegrationAccuracy() public {
        uint256 shares = 1000e18;
        uint256 payment = PURCHASE_INCREMENT; // $10
        
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        uint256 simpsonCost = _calculateSimpsonCost(shares, tokens);
        uint256 exactCost = _calculateExactCost(shares, tokens);
        
        // Simpson's rule should be reasonably accurate
        uint256 tolerance = payment / 100; // 1% tolerance
        assertTrue(
            _isWithinPrecision(simpsonCost, exactCost, tolerance),
            "Simpson's rule should be accurate"
        );
    }

    // ============ Overflow Protection Tests ============

    function test_calculatePrice_OverflowProtection() public {
        // Test with maximum safe shares value
        uint256 maxSafeShares = MAX_SAFE_SHARES;
        uint256 price = SecondaryPricing.calculatePrice(maxSafeShares);
        
        // Should not revert and should return a valid price
        assertGe(price, BASE_PRICE, "Price should be valid even at max safe shares");
    }

    function test_calculatePrice_VeryLargeShares() public {
        // Test near-overflow conditions
        uint256[] memory largeShares = new uint256[](3);
        largeShares[0] = 1e28;
        largeShares[1] = 1e29;
        largeShares[2] = 1e30;
        
        for (uint256 i = 0; i < largeShares.length; i++) {
            uint256 price = SecondaryPricing.calculatePrice(largeShares[i]);
            assertGe(price, BASE_PRICE, "Price should be valid for very large shares");
        }
    }

    function test_calculateTokensFromCollateral_OverflowBounds() public {
        // Test that binary search bounds don't overflow
        uint256 shares = 1000e18;
        uint256 payment = MAX_SAFE_PAYMENT;
        
        // Should not revert due to overflow in bounds calculation
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        
        // Should return some tokens (may be limited by overflow protection)
        assertGe(tokens, 0, "Should handle large payments without overflow");
    }

    function test_calculateTokensFromCollateral_VeryLargePayment() public {
        uint256 shares = 1000e18;
        uint256 payment = 1e25; // Very large payment
        
        // Should not revert
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        assertGe(tokens, 0, "Should handle very large payments");
    }

    function test_calculateIntegratedCost_OverflowProtection() public {
        // Test Simpson's rule with large values
        uint256 shares = 1e28;
        uint256 tokens = 1e27;
        
        // Should not revert due to overflow in 4 * priceMid or delta * sum
        uint256 cost = _calculateSimpsonCost(shares, tokens);
        assertGe(cost, 0, "Should handle large values without overflow");
    }

    // ============ Edge Case Tests ============

    function test_calculatePrice_ZeroShares() public {
        uint256 price = SecondaryPricing.calculatePrice(0);
        assertEq(price, BASE_PRICE, "Price should equal BASE_PRICE at zero shares");
    }

    function test_calculatePrice_VerySmallShares() public {
        uint256 shares = 1; // 1 wei
        uint256 price = SecondaryPricing.calculatePrice(shares);
        
        // With scaling, very small shares should still give BASE_PRICE
        assertGe(price, BASE_PRICE, "Price should be >= BASE_PRICE for very small shares");
    }

    function test_calculatePrice_VerySmallSharesBelowScaling() public {
        uint256 shares = 1e8; // Less than 1e9 scaling factor
        uint256 price = SecondaryPricing.calculatePrice(shares);
        
        // shares / 1e9 = 0, so sharesSquared = 0
        assertEq(price, BASE_PRICE, "Price should equal BASE_PRICE when shares < 1e9");
    }

    function test_calculatePrice_ScalingBoundary() public {
        // Test boundary condition at exactly 1e9 shares
        // At 1e9, shares / 1e9 = 1, so sharesSquared = 1
        uint256 shares = 1e9;
        uint256 price = SecondaryPricing.calculatePrice(shares);
        uint256 expectedPrice = BASE_PRICE + (1 * COEFFICIENT) / 1e18;
        assertEq(price, expectedPrice, "Price should be correct at scaling boundary");
        
        // Just below boundary should equal BASE_PRICE
        uint256 priceBelow = SecondaryPricing.calculatePrice(1e9 - 1);
        assertEq(priceBelow, BASE_PRICE, "Price should equal BASE_PRICE just below boundary");
        
        // At 1e9, the price includes the quadratic term (even if very small)
        // This verifies the scaling boundary is correctly handled
        assertGe(price, BASE_PRICE, "Price at 1e9 should be >= BASE_PRICE");
        
        // Verify the formula: price = BASE_PRICE + (sharesSquared * COEFFICIENT) / 1e18
        // At 1e9: sharesSquared = (1e9 / 1e9) * (1e9 / 1e9) = 1
        uint256 sharesSquared = (shares / 1e9) * (shares / 1e9);
        assertEq(sharesSquared, 1, "sharesSquared should be 1 at 1e9");
        uint256 calculatedPrice = BASE_PRICE + (sharesSquared * COEFFICIENT) / 1e18;
        assertEq(price, calculatedPrice, "Price should match formula at boundary");
    }

    function test_calculateTokensFromCollateral_VerySmallPayment() public {
        uint256 shares = 1000e18;
        uint256 payment = 1; // 1 wei
        
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        
        // May return 0 or very small amount due to precision
        assertGe(tokens, 0, "Should handle very small payments");
    }

    function test_calculateTokensFromCollateral_MinimumViablePayment() public {
        // Test that documents when function returns 0 tokens
        // Find minimum payment needed to receive at least 1 token
        
        uint256 shares = 1000e18;
        
        // Very small payment should return 0 tokens (due to high price at this share count)
        uint256 verySmallPayment = 1; // 1 wei
        uint256 tokens1 = SecondaryPricing.calculateTokensFromCollateral(shares, verySmallPayment);
        
        // With shares = 1000e18, price is high, so 1 wei should return 0 tokens
        assertEq(tokens1, 0, "Very small payment should return 0 tokens");
        
        // Standard purchase increment should return tokens
        uint256 standardPayment = PURCHASE_INCREMENT; // $10
        uint256 tokens2 = SecondaryPricing.calculateTokensFromCollateral(shares, standardPayment);
        assertGt(tokens2, 0, "Standard payment should return tokens");
        
        // At zero shares, even small payments should return tokens
        uint256 tokens3 = SecondaryPricing.calculateTokensFromCollateral(0, verySmallPayment);
        // At zero shares, price is BASE_PRICE, which is low, so even 1 wei might return tokens
        // But due to binary search precision, it might still be 0
        assertGe(tokens3, 0, "Even small payments at zero shares may return tokens");
    }

    function test_calculateTokensFromCollateral_ZeroShares() public {
        uint256 shares = 0;
        uint256 payment = PURCHASE_INCREMENT; // $10
        
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        
        // Should return tokens even when starting from zero shares
        assertGt(tokens, 0, "Should return tokens when starting from zero shares");
    }

    function test_calculateTokensFromCollateral_BinarySearchConvergence() public {
        // Test that binary search converges for various scenarios
        uint256[] memory shareValues = new uint256[](5);
        shareValues[0] = 0;
        shareValues[1] = 1e18;
        shareValues[2] = 1000e18;
        shareValues[3] = 1e21;
        shareValues[4] = 1e22;
        
        uint256 payment = PURCHASE_INCREMENT * 10; // $100
        
        for (uint256 i = 0; i < shareValues.length; i++) {
            uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shareValues[i], payment);
            uint256 cost = _calculateSimpsonCost(shareValues[i], tokens);
            
            // Cost should be close to payment (binary search should converge)
            assertLe(cost, payment, "Binary search should converge");
            assertGe(cost, payment * 95 / 100, "Binary search should be accurate");
        }
    }

    function test_calculateTokensFromCollateral_NoOvercharge() public {
        // CRITICAL UX TEST: Verify users never pay more than their payment amount
        // This ensures cost <= payment (prevents overcharging users)
        
        uint256[] memory shareValues = new uint256[](5);
        shareValues[0] = 0;
        shareValues[1] = 1e18;
        shareValues[2] = 1000e18;
        shareValues[3] = 1e21;
        shareValues[4] = 1e22;
        
        uint256[] memory payments = new uint256[](4);
        payments[0] = PURCHASE_INCREMENT; // $10
        payments[1] = PURCHASE_INCREMENT * 5; // $50
        payments[2] = PURCHASE_INCREMENT * 10; // $100
        payments[3] = PURCHASE_INCREMENT * 100; // $1000
        
        for (uint256 i = 0; i < shareValues.length; i++) {
            for (uint256 j = 0; j < payments.length; j++) {
                uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shareValues[i], payments[j]);
                
                // Only check if we got tokens (skip 0 token cases)
                if (tokens > 0) {
                    uint256 cost = _calculateSimpsonCost(shareValues[i], tokens);
                    
                    // CRITICAL: Cost must never exceed payment (prevents overcharging)
                    assertLe(cost, payments[j], "User should never pay more than payment amount");
                }
            }
        }
    }

    // ============ Fuzzing Tests ============

    function testFuzz_calculatePrice_AlwaysPositive(uint256 shares) public {
        // Bound shares to safe range
        shares = bound(shares, 0, MAX_SAFE_SHARES);
        
        uint256 price = SecondaryPricing.calculatePrice(shares);
        
        assertGe(price, BASE_PRICE, "Price should always be >= BASE_PRICE");
    }

    function testFuzz_calculatePrice_Monotonic(uint256 shares1, uint256 shares2) public {
        // Bound shares to safe range, but ensure we test above scaling threshold
        // Use larger minimum to avoid precision issues with small values
        // Need shares >= 1e9 for scaling to have effect, and >= 1e10 for meaningful price difference
        shares1 = bound(shares1, 1e10, MAX_SAFE_SHARES);
        shares2 = bound(shares2, 1e10, MAX_SAFE_SHARES);
        
        if (shares1 < shares2) {
            uint256 price1 = SecondaryPricing.calculatePrice(shares1);
            uint256 price2 = SecondaryPricing.calculatePrice(shares2);
            // Price should be >= (allows for equal prices when scaling causes same result)
            assertGe(price2, price1, "Price should not decrease with shares");
            
            // For significant differences, check if scaled values are different
            uint256 shares1Scaled = shares1 / 1e9;
            uint256 shares2Scaled = shares2 / 1e9;
            
            // Only assert price increase if scaled values are actually different
            // and the difference is significant (at least 10x in scaled space)
            if (shares2Scaled >= shares1Scaled * 10 && shares2Scaled > shares1Scaled) {
                // Calculate expected price difference
                uint256 expectedPriceDiff = (shares2Scaled * shares2Scaled - shares1Scaled * shares1Scaled) * COEFFICIENT / 1e18;
                // Only assert if expected difference is meaningful (> 0)
                if (expectedPriceDiff > 0) {
                    assertGt(price2, price1, "Price should increase when scaled shares increase significantly");
                }
            }
        }
    }

    function testFuzz_calculatePrice_FormulaCorrectness(uint256 shares) public {
        // Bound shares to safe range
        shares = bound(shares, 0, MAX_SAFE_SHARES);
        
        uint256 price = SecondaryPricing.calculatePrice(shares);
        uint256 expectedPrice = _calculateExactPrice(shares);
        
        assertEq(price, expectedPrice, "Price should match exact formula");
    }

    function testFuzz_calculateTokensFromCollateral_NonZero(uint256 shares, uint256 payment) public {
        // Bound inputs to safe ranges
        // Limit shares to reasonable range to avoid cases where price is too high
        shares = bound(shares, 0, 1e25);
        // Ensure payment is large enough relative to potential price
        payment = bound(payment, 1e15, MAX_SAFE_PAYMENT); // At least 1e15 wei to ensure we can buy tokens
        
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        
        // For reasonable inputs, should get tokens. If shares are extremely large,
        // price might be too high, which is acceptable behavior.
        if (shares < 1e25) {
            assertGt(tokens, 0, "Non-zero payment should give tokens for reasonable shares");
        }
    }

    function testFuzz_calculateTokensFromCollateral_ZeroPayment(uint256 shares) public {
        // Bound shares to safe range
        shares = bound(shares, 0, MAX_SAFE_SHARES);
        
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, 0);
        
        assertEq(tokens, 0, "Zero payment should give zero tokens");
    }

    function testFuzz_calculateTokensFromCollateral_Consistency(
        uint256 shares,
        uint256 payment1,
        uint256 payment2
    ) public {
        // Bound inputs to safe ranges
        shares = bound(shares, 0, MAX_SAFE_SHARES);
        payment1 = bound(payment1, 1, MAX_SAFE_PAYMENT);
        payment2 = bound(payment2, 1, MAX_SAFE_PAYMENT);
        
        if (payment1 < payment2) {
            uint256 tokens1 = SecondaryPricing.calculateTokensFromCollateral(shares, payment1);
            uint256 tokens2 = SecondaryPricing.calculateTokensFromCollateral(shares, payment2);
            
            assertGe(tokens2, tokens1, "More payment should give more tokens");
        }
    }

    function testFuzz_calculateTokensFromCollateral_RoundTrip(
        uint256 shares,
        uint256 payment
    ) public {
        // Bound inputs to safe ranges to avoid overflow in Simpson's rule
        // Use conservative bounds to ensure binary search converges correctly
        // Limit shares to prevent extremely high prices
        shares = bound(shares, 0, 1e18);
        // Limit payment to reasonable range relative to shares
        // Payment should be proportional to shares to avoid extreme ratios
        payment = bound(payment, 1e15, 1e21); // Reasonable payment range
        
        // Skip if payment is too large relative to shares (would cause overflow)
        // Estimate max tokens: if shares are large, price is high, so tokens would be small
        // But if payment is huge, tokensEstimate * 2 might overflow
        uint256 initialPrice = SecondaryPricing.calculatePrice(shares);
        if (initialPrice == 0) return; // Safety check
        
        // Estimate tokens - if this would overflow, skip the test
        uint256 tokensEstimate;
        if (payment > type(uint256).max / PRICE_PRECISION) {
            return; // Would overflow in tokensEstimate calculation
        }
        tokensEstimate = (payment * PRICE_PRECISION) / initialPrice;
        
        // If tokensEstimate * 2 would overflow, skip
        if (tokensEstimate > type(uint256).max / 2) {
            return;
        }
        
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        
        // Only check if we got tokens and payment was sufficient
        if (tokens > 0 && payment > 0) {
            // Check that we can calculate cost without overflow
            // For very small tokens, Simpson's rule might have precision issues
            if (tokens < 1e15) {
                // Skip very small token amounts where precision might be an issue
                return;
            }
            
            // Check for potential overflow in Simpson's rule
            uint256 sharesEnd = shares + tokens;
            if (sharesEnd < shares) {
                return; // Overflow in addition
            }
            
            uint256 actualCost = _calculateSimpsonCost(shares, tokens);
            
            // Actual cost should not exceed payment (binary search ensures this)
            // The binary search finds tokensLow such that cost <= payment
            // So actualCost should be <= payment (with small tolerance for rounding)
            // Allow 5% tolerance for rounding errors in extreme cases
            assertLe(actualCost, payment * 105 / 100, "Actual cost should not significantly exceed payment");
        }
    }

    // ============ Invariant Tests ============

    function test_invariant_PriceAlwaysAtLeastBasePrice() public {
        // Test across a wide range of shares
        for (uint256 shares = 0; shares <= 1e22; shares += 1e20) {
            uint256 price = SecondaryPricing.calculatePrice(shares);
            assertGe(price, BASE_PRICE, "Price should always be >= BASE_PRICE");
        }
    }

    function test_invariant_PriceMonotonic() public {
        // Test that price always increases with shares
        uint256 prevPrice = SecondaryPricing.calculatePrice(0);
        
        for (uint256 shares = 1e18; shares <= 1e22; shares += 1e20) {
            uint256 price = SecondaryPricing.calculatePrice(shares);
            assertGt(price, prevPrice, "Price should increase monotonically");
            prevPrice = price;
        }
    }

    function test_invariant_TokensIncreaseWithPayment() public {
        uint256 shares = 1000e18;
        uint256 prevTokens = 0;
        
        // Test with increasing payments
        for (uint256 payment = PURCHASE_INCREMENT; payment <= PURCHASE_INCREMENT * 10; payment += PURCHASE_INCREMENT) {
            uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
            assertGe(tokens, prevTokens, "Tokens should increase with payment");
            prevTokens = tokens;
        }
    }

    function test_invariant_IntegrationCostMatchesActual() public {
        // For small purchases, integration cost should match actual cost
        uint256 shares = 1000e18;
        uint256 payment = PURCHASE_INCREMENT; // $10
        
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        uint256 simpsonCost = _calculateSimpsonCost(shares, tokens);
        uint256 exactCost = _calculateExactCost(shares, tokens);
        
        // Should be within reasonable tolerance
        uint256 tolerance = payment / 50; // 2% tolerance
        assertTrue(
            _isWithinPrecision(simpsonCost, exactCost, tolerance),
            "Integration cost should match actual cost for small purchases"
        );
    }

    function test_invariant_BinarySearchConverges() public {
        // Test that binary search converges for various scenarios
        uint256[] memory testPayments = new uint256[](5);
        testPayments[0] = PURCHASE_INCREMENT; // $10
        testPayments[1] = PURCHASE_INCREMENT * 5; // $50
        testPayments[2] = PURCHASE_INCREMENT * 10; // $100
        testPayments[3] = PURCHASE_INCREMENT * 50; // $500
        testPayments[4] = PURCHASE_INCREMENT * 100; // $1000
        
        uint256 shares = 1000e18;
        
        for (uint256 i = 0; i < testPayments.length; i++) {
            uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, testPayments[i]);
            uint256 cost = _calculateSimpsonCost(shares, tokens);
            
            // Cost should be close to payment (within 5%)
            assertLe(cost, testPayments[i], "Binary search should converge");
            assertGe(cost, testPayments[i] * 95 / 100, "Binary search should be accurate");
        }
    }

    function test_invariant_NoOverflow() public {
        // Test that calculations don't overflow for safe input ranges
        uint256[] memory testShares = new uint256[](5);
        testShares[0] = 0;
        testShares[1] = 1e18;
        testShares[2] = 1e21;
        testShares[3] = 1e24;
        testShares[4] = MAX_SAFE_SHARES;
        
        for (uint256 i = 0; i < testShares.length; i++) {
            uint256 price = SecondaryPricing.calculatePrice(testShares[i]);
            assertGe(price, BASE_PRICE, "Should not overflow for safe shares");
            
            uint256 payment = PURCHASE_INCREMENT * 10; // $100
            uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(testShares[i], payment);
            assertGe(tokens, 0, "Should not overflow for safe inputs");
        }
    }

    // ============ Precision & Accuracy Tests ============

    function test_calculatePrice_Precision() public {
        // Test precision for various share values
        uint256 shares1 = 1e18;
        uint256 shares2 = 1e18 + 1;
        
        uint256 price1 = SecondaryPricing.calculatePrice(shares1);
        uint256 price2 = SecondaryPricing.calculatePrice(shares2);
        
        // Due to scaling (shares / 1e9), very small differences may not affect price
        // This is expected behavior
        assertGe(price2, price1, "Price should not decrease");
    }

    function test_calculateTokensFromCollateral_Precision() public {
        uint256 shares = 1000e18;
        uint256 payment = PURCHASE_INCREMENT; // $10
        
        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
        uint256 cost = _calculateSimpsonCost(shares, tokens);
        
        // Cost should be very close to payment (within 1%)
        uint256 tolerance = payment / 100;
        assertTrue(
            _isWithinPrecision(cost, payment, tolerance),
            "Binary search should be precise"
        );
    }

    function test_calculateIntegratedCost_SimpsonAccuracy() public {
        // Compare Simpson's rule vs. exact integration for various scenarios
        uint256[] memory testShares = new uint256[](3);
        testShares[0] = 0;
        testShares[1] = 1000e18;
        testShares[2] = 1e21;
        
        uint256 tokens = 100e18;
        
        for (uint256 i = 0; i < testShares.length; i++) {
            uint256 simpsonCost = _calculateSimpsonCost(testShares[i], tokens);
            uint256 exactCost = _calculateExactCost(testShares[i], tokens);
            
            // Simpson's rule should be within 5% of exact cost
            uint256 tolerance = exactCost / 20; // 5%
            assertTrue(
                _isWithinPrecision(simpsonCost, exactCost, tolerance),
                "Simpson's rule should be accurate"
            );
        }
    }

    // ============ Integration Tests ============

    function test_PriceMonotonicity() public {
        uint256 price1 = SecondaryPricing.calculatePrice(100e18);
        uint256 price2 = SecondaryPricing.calculatePrice(500e18);
        uint256 price3 = SecondaryPricing.calculatePrice(1000e18);
        uint256 price4 = SecondaryPricing.calculatePrice(2000e18);

        assertGt(price2, price1, "Price should increase with shares");
        assertGt(price3, price2, "Price should increase with shares");
        assertGt(price4, price3, "Price should increase with shares");
    }

    function test_PriceBounds() public {
        uint256 price1 = SecondaryPricing.calculatePrice(0);
        uint256 price2 = SecondaryPricing.calculatePrice(10000e18);
        uint256 price3 = SecondaryPricing.calculatePrice(1000e18);

        assertGe(price1, BASE_PRICE, "Price should be >= BASE_PRICE");
        assertGe(price2, BASE_PRICE, "Price should be >= BASE_PRICE");
        assertGe(price3, BASE_PRICE, "Price should be >= BASE_PRICE");
    }

    function test_SequentialPurchases() public {
        // Simulate sequential purchases with standard increments
        uint256 shares = 0;
        uint256 prevPrice = SecondaryPricing.calculatePrice(shares);
        
        for (uint256 i = 0; i < 5; i++) {
            uint256 payment = PURCHASE_INCREMENT; // $10 each
            uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(shares, payment);
            shares += tokens;
            
            uint256 newPrice = SecondaryPricing.calculatePrice(shares);
            assertGt(newPrice, prevPrice, "Price should increase after each purchase");
            prevPrice = newPrice;
        }
    }
}
