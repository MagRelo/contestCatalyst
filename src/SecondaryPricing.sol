// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SecondaryPricing
 * @dev Clean polynomial bonding curve pricing implementation
 * 
 * Price Formula: price = BASE_PRICE + COEFFICIENT * shares^2
 * 
 * Properties:
 * - Price increases quadratically with supply (whale protection)
 * - Early bettors get better prices (lower supply = lower price)
 * - Large purchases cause dramatic price increases
 */
library SecondaryPricing {
    /// @notice Price precision (1.0 = 1e6)
    uint256 public constant PRICE_PRECISION = 1e6;
    
    /// @notice Minimum price per token
    uint256 public constant BASE_PRICE = 1e6; // 1.0
    
    /// @notice Coefficient for quadratic term
    /// @dev Higher values = steeper curve = more whale protection
    uint256 public constant COEFFICIENT = 1; // Scaled appropriately for shares^2

    /**
     * @notice Calculate current price per token
     * @param shares Current shares for this entry
     * @return price Price per token (scaled by PRICE_PRECISION)
     */
    function calculatePrice(uint256 shares) internal pure returns (uint256) {
        // Polynomial bonding curve: price = BASE_PRICE + COEFFICIENT * shares^2
        uint256 sharesSquared = (shares / 1e9) * (shares / 1e9); // shares^2 scaled to avoid overflow
        return BASE_PRICE + (sharesSquared * COEFFICIENT) / 1e18;
    }

    /**
     * @notice Calculate tokens received for a payment amount
     * @param shares Current shares before purchase
     * @param payment Amount to spend
     * @return tokensToMint Tokens received
     */
    function calculateTokensFromCollateral(
        uint256 shares,
        uint256 payment
    ) internal pure returns (uint256 tokensToMint) {
        if (payment == 0) {
            return 0;
        }
        
        // For quadratic curve: cost = ∫[s to s+t] (BASE_PRICE + COEFFICIENT * x^2) dx
        //                    = BASE_PRICE * t + COEFFICIENT * ((s+t)^3 - s^3) / 3
        // Use binary search to solve for t
        
        uint256 initialPrice = calculatePrice(shares);
        uint256 tokensEstimate = (payment * PRICE_PRECISION) / initialPrice;
        
        // Binary search bounds
        uint256 tokensLow = tokensEstimate / 2;
        uint256 tokensHigh = tokensEstimate * 2;
        
        // Binary search for correct token amount
        for (uint256 i = 0; i < 50; i++) {
            if (tokensHigh <= tokensLow + 1) break;
            
            uint256 tokensMid = (tokensLow + tokensHigh) / 2;
            uint256 cost = _calculateIntegratedCost(shares, tokensMid);
            
            if (cost < payment) {
                tokensLow = tokensMid;
            } else {
                tokensHigh = tokensMid;
            }
        }
        
        tokensToMint = tokensLow;
    }

    /**
     * @notice Calculate integrated cost for purchasing tokens
     * @param sharesInitial Initial shares before purchase
     * @param tokensToBuy Number of tokens to purchase
     * @return cost Total cost in collateral units
     */
    function _calculateIntegratedCost(
        uint256 sharesInitial,
        uint256 tokensToBuy
    ) private pure returns (uint256 cost) {
        if (tokensToBuy == 0) {
            return 0;
        }
        
        // Simpson's rule: ∫[a to b] f(x) dx ≈ (b-a)/6 * [f(a) + 4*f((a+b)/2) + f(b)]
        uint256 sharesStart = sharesInitial;
        uint256 sharesEnd = sharesInitial + tokensToBuy;
        uint256 sharesMid = (sharesStart + sharesEnd) / 2;
        
        uint256 priceStart = calculatePrice(sharesStart);
        uint256 priceMid = calculatePrice(sharesMid);
        uint256 priceEnd = calculatePrice(sharesEnd);
        
        uint256 delta = sharesEnd - sharesStart;
        uint256 sum = priceStart + (4 * priceMid) + priceEnd;
        cost = (delta * sum) / (6 * PRICE_PRECISION);
    }
}
