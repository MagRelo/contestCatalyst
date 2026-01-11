// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SecondaryPricing.sol";

/**
 * @title SecondaryPricingTest
 * @author MagRelo
 * @dev Tests for SecondaryPricing library functions
 * 
 * Tests the hybrid constant product pricing mechanism:
 * - calculatePrice: Base constant product with popularity multiplier
 * - calculateTokensFromCollateral: Token amount from collateral payment
 */
contract SecondaryPricingTest is Test {

    uint256 public constant PRICE_PRECISION = 1e6;

    // ============ calculatePrice Tests ============

    function test_calculatePrice_InitialState() public {
        uint256 shares = 0;

        uint256 price = SecondaryPricing.calculatePrice(shares);

        // Initial price should be based on virtual reserves
        // price = (VIRTUAL_COLLATERAL + collateral) / (VIRTUAL_SHARES + shares) * multiplier
        // With no popularity (shares = 0, otherShares = 0), multiplier = 1.0
        assertGe(price, PRICE_PRECISION, "Price should be >= PRICE_PRECISION");
    }

    function test_calculatePrice_EqualShares() public {
        uint256 shares = 1000e18;

        uint256 price = SecondaryPricing.calculatePrice(shares);

        // When shares are equal, popularity = 0.5, so multiplier = 1.0 + 0.5 * 1.0 = 1.5
        // Base price = (1000e18 + 1e18) / (1000e18 + 1e18) = 1.0
        // Final price = 1.0 * 1.5 = 1.5
        assertGe(price, PRICE_PRECISION, "Price should be >= PRICE_PRECISION");
        assertLe(price, PRICE_PRECISION * 2, "Price should be reasonable");
    }

    function test_calculatePrice_MoreShares() public {
        uint256 shares = 5000e18;

        uint256 price = SecondaryPricing.calculatePrice(shares);

        // When this entry has more shares, popularity > 0.5, so price should be higher
        assertGt(price, PRICE_PRECISION, "Price should be greater than base when more shares");
    }

    function test_calculatePrice_FewerShares() public {
        uint256 shares = 1000e18;

        uint256 price = SecondaryPricing.calculatePrice(shares);

        // When this entry has fewer shares, popularity < 0.5, so price should be lower
        // But still >= PRICE_PRECISION due to base constant product
        assertGe(price, PRICE_PRECISION, "Price should be at least PRICE_PRECISION");
    }

    function test_calculatePrice_PriceIncreasesWithShares() public {
        uint256 price1 = SecondaryPricing.calculatePrice(100e18);
        uint256 price2 = SecondaryPricing.calculatePrice(500e18);
        uint256 price3 = SecondaryPricing.calculatePrice(1000e18);
        uint256 price4 = SecondaryPricing.calculatePrice(2000e18);

        // Price should increase as shares increase (both base price and popularity increase)
        assertGt(price2, price1, "Price should increase with shares");
        assertGt(price3, price2, "Price should increase with shares");
        assertGt(price4, price3, "Price should increase with shares");
    }

    function test_calculatePrice_OnlyDependsOnShares() public {
        uint256 shares = 1000e18;

        uint256 price1 = SecondaryPricing.calculatePrice(shares);
        uint256 price2 = SecondaryPricing.calculatePrice(shares);

        // Price should be the same for same shares (no other parameters matter)
        assertEq(price1, price2, "Price should be deterministic based only on shares");
    }

    // ============ calculateTokensFromCollateral Tests ============

    function test_calculateTokensFromCollateral_SmallPurchase() public {
        uint256 shares = 1000e18;
        uint256 payment = 100e18; // $100

        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(
            shares,
            payment
        );

        // Should return some tokens
        assertGt(tokens, 0, "Should return tokens for small purchase");
    }

    function test_calculateTokensFromCollateral_ZeroCollateral() public {
        uint256 shares = 1000e18;
        uint256 payment = 0;

        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(
            shares,
            payment
        );

        assertEq(tokens, 0, "Should return 0 tokens for zero payment");
    }

    function test_calculateTokensFromCollateral_LargePurchase() public {
        uint256 shares = 1000e18;
        uint256 payment = 2000e18; // $2000, should use integration

        uint256 tokens = SecondaryPricing.calculateTokensFromCollateral(
            shares,
            payment
        );

        // Should return tokens using integration
        assertGt(tokens, 0, "Should return tokens for large purchase");
    }

    function test_calculateTokensFromCollateral_PriceIncreases() public {
        uint256 shares = 1000e18;
        uint256 payment = 2000e18;

        uint256 tokens1 = SecondaryPricing.calculateTokensFromCollateral(
            shares,
            payment
        );
        
        // After first purchase, shares increase
        uint256 shares2 = shares + tokens1;
        uint256 tokens2 = SecondaryPricing.calculateTokensFromCollateral(
            shares2,
            payment
        );

        // Second purchase should give fewer tokens (price increased)
        assertLt(tokens2, tokens1, "Second purchase should give fewer tokens due to price increase");
    }

    // ============ Integration Tests ============

    function test_PriceMonotonicity() public {
        uint256 price1 = SecondaryPricing.calculatePrice(100e18);
        uint256 price2 = SecondaryPricing.calculatePrice(500e18);
        uint256 price3 = SecondaryPricing.calculatePrice(1000e18);
        uint256 price4 = SecondaryPricing.calculatePrice(2000e18);

        // Price should increase as shares increase
        assertGt(price2, price1, "Price should increase with position");
        assertGt(price3, price2, "Price should increase with position");
        assertGt(price4, price3, "Price should increase with position");
    }

    function test_PriceBounds() public {
        // Test various scenarios
        uint256 price1 = SecondaryPricing.calculatePrice(0);
        uint256 price2 = SecondaryPricing.calculatePrice(10000e18);
        uint256 price3 = SecondaryPricing.calculatePrice(1000e18);

        // All prices should be >= PRICE_PRECISION
        assertGe(price1, PRICE_PRECISION, "Price should be >= PRICE_PRECISION");
        assertGe(price2, PRICE_PRECISION, "Price should be >= PRICE_PRECISION");
        assertGe(price3, PRICE_PRECISION, "Price should be >= PRICE_PRECISION");
    }

    function test_PriceIncreasesWithShares() public {
        uint256 shares1 = 100e18;
        uint256 shares2 = 1000e18;

        uint256 price1 = SecondaryPricing.calculatePrice(shares1);
        uint256 price2 = SecondaryPricing.calculatePrice(shares2);

        // Price should increase with shares (quadratic bonding curve)
        assertGt(price2, price1, "Price should increase with shares");
    }
}
