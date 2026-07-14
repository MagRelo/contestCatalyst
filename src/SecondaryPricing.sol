// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SecondaryPricing
 * @dev Polynomial bonding curve. Share supply and collateral inputs are always in
 *      18-decimal share units (`SHARE_DECIMALS`), independent of payment-token decimals.
 *      Callers must normalize payment amounts via `toShareUnits` before mint pricing.
 *
 * Price Formula: price = BASE_PRICE + COEFFICIENT * shares^2
 *
 * Properties:
 * - Price increases quadratically with supply (whale protection)
 * - Early bettors get better prices (lower supply = lower price)
 * - Large purchases cause dramatic price increases
 */
library SecondaryPricing {
    /// @notice Share / curve unit decimals (always 18; not payment-token decimals)
    uint256 public constant SHARE_DECIMALS = 18;

    /// @notice Price precision (1.0 = 1e6)
    uint256 public constant PRICE_PRECISION = 1e6;

    /// @notice Minimum price per token
    uint256 public constant BASE_PRICE = 1e6; // 1.0

    /// @notice Coefficient for quadratic term
    /// @dev Higher values = steeper curve = more whale protection
    uint256 public constant COEFFICIENT = 15; // Tuned for realistic early-buyer / whale friction (see SecondaryPricingTuning.md)

    /**
     * @notice Scale a payment-token amount into 18-decimal share units for curve math
     * @param paymentAmount Amount in payment-token native decimals
     * @param paymentDecimals ERC20 decimals of the payment token
     * @return Amount in SHARE_DECIMALS units (1e18 ≈ $1 face at BASE_PRICE when token has 18 decimals)
     */
    function toShareUnits(uint256 paymentAmount, uint8 paymentDecimals) internal pure returns (uint256) {
        if (paymentDecimals == SHARE_DECIMALS) {
            return paymentAmount;
        }
        if (paymentDecimals < SHARE_DECIMALS) {
            uint256 scale = 10 ** (SHARE_DECIMALS - paymentDecimals);
            require(paymentAmount <= type(uint256).max / scale, "Payment scale overflow");
            return paymentAmount * scale;
        }
        return paymentAmount / (10 ** (paymentDecimals - SHARE_DECIMALS));
    }

    /**
     * @notice Calculate current price per token
     * @param shares Current shares for this entry (18-decimal share units)
     * @return price Price per share unit (scaled by PRICE_PRECISION)
     */
    function calculatePrice(uint256 shares) internal pure returns (uint256) {
        // Polynomial bonding curve: price = BASE_PRICE + COEFFICIENT * shares^2
        // Scaling: shares < 1e9 always result in BASE_PRICE (prevents overflow)
        uint256 sharesSquared = (shares / 1e9) * (shares / 1e9); // shares^2 scaled to avoid overflow
        return BASE_PRICE + (sharesSquared * COEFFICIENT) / 1e18;
    }

    /**
     * @notice Calculate tokens received for a payment amount
     * @param shares Current shares before purchase (18-decimal share units)
     * @param payment Amount to spend in 18-decimal share units (use `toShareUnits` first)
     * @return tokensToMint Tokens received in share units (may be 0 if payment is insufficient)
     * @dev Returns 0 if payment is insufficient to purchase at least 1 wei of shares
     * @dev Caller should check return value and revert if tokensToMint == 0 for non-zero payment
     */
    function calculateTokensFromCollateral(uint256 shares, uint256 payment)
        internal
        pure
        returns (uint256 tokensToMint)
    {
        if (payment == 0) {
            return 0;
        }

        // For quadratic curve: cost = ∫[s to s+t] (BASE_PRICE + COEFFICIENT * x^2) dx
        //                    = BASE_PRICE * t + COEFFICIENT * ((s+t)^3 - s^3) / 3
        // Use binary search to solve for t. Cost is also in 18-decimal share units.

        uint256 initialPrice = calculatePrice(shares);
        uint256 tokensEstimate = (payment * PRICE_PRECISION) / initialPrice;
        if (tokensEstimate == 0) {
            return 0;
        }

        // Bounds must sandwich the payment: cost(low) < payment <= cost(high).
        // On steep curves, estimate/2 can already overshoot payment, so low starts at 0
        // and high is expanded until the integral cost meets or exceeds payment.
        uint256 tokensLow = 0;
        uint256 tokensHigh = tokensEstimate * 2;
        if (tokensHigh < 2) {
            tokensHigh = 2;
        }
        for (uint256 e = 0; e < 32; e++) {
            if (_calculateIntegratedCost(shares, tokensHigh) >= payment) break;
            if (tokensHigh > type(uint256).max / 2) break;
            tokensHigh *= 2;
        }

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
     * @notice Calculate integrated cost for purchasing tokens (18-decimal share units)
     * @param sharesInitial Initial shares before purchase
     * @param tokensToBuy Number of tokens to purchase
     * @return cost Total cost in 18-decimal share units
     */
    function _calculateIntegratedCost(uint256 sharesInitial, uint256 tokensToBuy)
        private
        pure
        returns (uint256 cost)
    {
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
