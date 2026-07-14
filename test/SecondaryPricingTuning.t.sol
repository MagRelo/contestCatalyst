// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SecondaryPricing.sol";

/**
 * @title SecondaryPricingTuning
 * @dev PARAMETER SWEEP - not assertion-gated unit tests.
 *
 * Duplicates SecondaryPricing math with tunable (shareDivisor, coefficient) so we can
 * find curve params that meet documented early-buyer / whale-friction goals without
 * mutating src/SecondaryPricing.sol.
 *
 * Run: forge test --match-path test/SecondaryPricingTuning.t.sol -vv
 */
contract SecondaryPricingTuning is Test {
    uint256 public constant PRICE_PRECISION = 1e6;
    uint256 public constant BASE_PRICE = 1e6;
    uint256 public constant COEFF_SCALE = 1e18;
    uint256 public constant PURCHASE_INCREMENT = 10e18;

    // --- Hard thresholds (plan) ---
    uint256 public constant EARLY_ADVANTAGE_BPS = 12_500; // >=1.25x early/late token ratio
    uint256 public constant WHALE_PRICE_MOVE_BPS = 12_500; // >=1.25x spot after whale
    uint256 public constant POST_WHALE_TOKEN_BPS = 5_000; // late tokens <=50% of first $10
    uint256 public constant CURVE_ENGAGED_BPS = 10_500; // price @ 100e18 >=1.05x base
    uint256 public constant MIN_FIRST_BUY_TOKENS = 7e18;
    uint256 public constant FRONT_RUN_AVG_PRICE_BPS = 11_500; // >=1.15x base avg on $5k

    uint256 public constant METRIC_COUNT = 6;

    struct CurveParams {
        uint256 shareDivisor;
        uint256 coefficient;
    }

    struct Metrics {
        uint256 earlyTokens;
        uint256 lateTokens;
        uint256 earlyAdvantageBps; // early/late * 10000
        uint256 whalePriceBefore;
        uint256 whalePriceAfter;
        uint256 whalePriceMoveBps;
        uint256 firstBuyTokens;
        uint256 postWhaleTokens;
        uint256 postWhaleTokenBps; // postWhale/first * 10000
        uint256 priceAt100;
        uint256 priceAt100Bps; // / BASE * 10000
        uint256 frontRunTokens;
        uint256 frontRunAvgPriceBps; // payment * PRICE_PRECISION / tokens / BASE * 10000
        uint256 breakevenPurchase; // 0 if none within cap
        uint8 passCount;
        bool passEarly;
        bool passWhale;
        bool passPostWhale;
        bool passCurve;
        bool passNotTooSteep;
        bool passFrontRun;
    }

    struct RankedCandidate {
        CurveParams params;
        Metrics metrics;
        bool isBaseline;
    }

    function test_ParameterSweep() public {
        console.log("=== Secondary Pricing Parameter Tuning Sweep ===");
        console.log("Formula: price = BASE + ((shares/shareDivisor)^2 * coefficient) / 1e18");
        console.log("BASE_PRICE = 1e6, COEFF_SCALE = 1e18");
        console.log("");

        // Baseline = production SecondaryPricing.sol constants
        CurveParams memory baseline = CurveParams({
            shareDivisor: 1e9,
            coefficient: SecondaryPricing.COEFFICIENT
        });
        Metrics memory baselineMetrics = _evaluate(baseline);
        _logCandidate("BASELINE (current)", baseline, baselineMetrics, true);

        // Cross-check baseline spot price against live library at 100e18
        uint256 livePrice = SecondaryPricing.calculatePrice(100e18);
        uint256 paramPrice = _calculatePrice(100e18, baseline.shareDivisor, baseline.coefficient);
        require(livePrice == paramPrice, "baseline price must match SecondaryPricing");

        uint256[] memory divisors = _shareDivisors();
        uint256[] memory coefficients = _coefficients();

        RankedCandidate[5] memory topPass;
        uint256 topPassCount;
        RankedCandidate[5] memory topNear;
        uint256 topNearCount;

        uint256 evaluated;
        uint256 allPassCount;

        for (uint256 di; di < divisors.length; di++) {
            for (uint256 ci; ci < coefficients.length; ci++) {
                CurveParams memory p =
                    CurveParams({shareDivisor: divisors[di], coefficient: coefficients[ci]});

                // Skip exact baseline duplicate in ranking loops (already logged)
                bool isBaseline =
                    (p.shareDivisor == baseline.shareDivisor && p.coefficient == baseline.coefficient);
                Metrics memory m = isBaseline ? baselineMetrics : _evaluate(p);
                evaluated++;

                if (m.passCount == METRIC_COUNT) {
                    allPassCount++;
                    _insertRanked(topPass, topPassCount, p, m, isBaseline, true);
                    if (topPassCount < 5) topPassCount++;
                } else {
                    _insertRanked(topNear, topNearCount, p, m, isBaseline, false);
                    if (topNearCount < 5) topNearCount++;
                }
            }
        }

        console.log("");
        console.log("=== Sweep summary ===");
        console.log("Candidates evaluated: %s", evaluated);
        console.log("All-pass candidates: %s", allPassCount);

        console.log("");
        console.log("=== Top all-pass shortlist ===");
        if (topPassCount == 0) {
            console.log("(none)");
        } else {
            for (uint256 i; i < topPassCount; i++) {
                string memory label = string.concat("PASS #", vm.toString(i + 1));
                _logCandidate(label, topPass[i].params, topPass[i].metrics, topPass[i].isBaseline);
            }
        }

        console.log("");
        console.log("=== Best near-miss shortlist (by passCount, then earlyAdvantage) ===");
        for (uint256 i; i < topNearCount; i++) {
            string memory label = string.concat("NEAR #", vm.toString(i + 1));
            _logCandidate(label, topNear[i].params, topNear[i].metrics, topNear[i].isBaseline);
        }

        console.log("");
        console.log("=== Recommendation ===");
        if (topPassCount > 0) {
            CurveParams memory rec = topPass[0].params;
            console.log("Recommended shareDivisor: %s", rec.shareDivisor);
            console.log("Recommended coefficient:  %s", rec.coefficient);
            console.log(
                "Replace SecondaryPricing: sharesSquared = (shares / %s) * (shares / %s);",
                rec.shareDivisor,
                rec.shareDivisor
            );
            console.log("COEFFICIENT = %s;  (COEFF_SCALE stays 1e18)", rec.coefficient);
            console.log("NOTE: recommendation only - contract constants unchanged this pass.");
        } else {
            console.log("No all-pass candidate. Inspect near-misses / widen grid.");
        }
    }

    // -------------------------------------------------------------------------
    // Grid
    // -------------------------------------------------------------------------

    function _shareDivisors() internal pure returns (uint256[] memory d) {
        d = new uint256[](9);
        d[0] = 5e7;
        d[1] = 1e8;
        d[2] = 2e8;
        d[3] = 5e8;
        d[4] = 1e9; // production
        d[5] = 2e9;
        d[6] = 5e9;
        d[7] = 1e10;
        d[8] = 2e10;
    }

    function _coefficients() internal pure returns (uint256[] memory c) {
        c = new uint256[](17);
        c[0] = 1; // production
        c[1] = 5;
        c[2] = 10;
        c[3] = 12; // ~equiv curvature to (2e9, 50) with D=1e9
        c[4] = 15;
        c[5] = 20;
        c[6] = 50;
        c[7] = 100;
        c[8] = 200;
        c[9] = 500;
        c[10] = 1_000;
        c[11] = 2_000;
        c[12] = 5_000;
        c[13] = 10_000;
        c[14] = 50_000;
        c[15] = 100_000;
        c[16] = 25;
    }

    // -------------------------------------------------------------------------
    // Parameterized pricing (mirrors SecondaryPricing)
    // -------------------------------------------------------------------------

    function _calculatePrice(uint256 shares, uint256 shareDivisor, uint256 coefficient)
        internal
        pure
        returns (uint256)
    {
        uint256 scaled = shares / shareDivisor;
        uint256 sharesSquared = scaled * scaled;
        return BASE_PRICE + (sharesSquared * coefficient) / COEFF_SCALE;
    }

    function _integratedCost(
        uint256 sharesInitial,
        uint256 tokensToBuy,
        uint256 shareDivisor,
        uint256 coefficient
    ) internal pure returns (uint256 cost) {
        if (tokensToBuy == 0) return 0;
        uint256 sharesStart = sharesInitial;
        uint256 sharesEnd = sharesInitial + tokensToBuy;
        uint256 sharesMid = (sharesStart + sharesEnd) / 2;
        uint256 priceStart = _calculatePrice(sharesStart, shareDivisor, coefficient);
        uint256 priceMid = _calculatePrice(sharesMid, shareDivisor, coefficient);
        uint256 priceEnd = _calculatePrice(sharesEnd, shareDivisor, coefficient);
        uint256 delta = sharesEnd - sharesStart;
        uint256 sum = priceStart + (4 * priceMid) + priceEnd;
        cost = (delta * sum) / (6 * PRICE_PRECISION);
    }

    function _tokensFromCollateral(
        uint256 shares,
        uint256 payment,
        uint256 shareDivisor,
        uint256 coefficient
    ) internal pure returns (uint256 tokensToMint) {
        if (payment == 0) return 0;
        uint256 initialPrice = _calculatePrice(shares, shareDivisor, coefficient);
        if (initialPrice == 0) return 0;
        uint256 tokensEstimate = (payment * PRICE_PRECISION) / initialPrice;
        if (tokensEstimate == 0) return 0;

        // Match SecondaryPricing.sol: low starts at 0; expand high until cost >= payment
        uint256 tokensLow = 0;
        uint256 tokensHigh = tokensEstimate * 2;
        if (tokensHigh < 2) tokensHigh = 2;
        for (uint256 e; e < 32; e++) {
            if (_integratedCost(shares, tokensHigh, shareDivisor, coefficient) >= payment) break;
            if (tokensHigh > type(uint256).max / 2) break;
            tokensHigh *= 2;
        }

        for (uint256 i; i < 50; i++) {
            if (tokensHigh <= tokensLow + 1) break;
            uint256 tokensMid = (tokensLow + tokensHigh) / 2;
            uint256 cost = _integratedCost(shares, tokensMid, shareDivisor, coefficient);
            if (cost < payment) {
                tokensLow = tokensMid;
            } else {
                tokensHigh = tokensMid;
            }
        }
        tokensToMint = tokensLow;
    }

    function _buy(uint256 supply, uint256 payment, CurveParams memory p)
        internal
        pure
        returns (uint256 tokens, uint256 newSupply)
    {
        tokens = _tokensFromCollateral(supply, payment, p.shareDivisor, p.coefficient);
        newSupply = supply + tokens;
    }

    // -------------------------------------------------------------------------
    // Metrics
    // -------------------------------------------------------------------------

    function _evaluate(CurveParams memory p) internal pure returns (Metrics memory m) {
        // EarlyAdvantage: $10 at 0 vs $10 after $150 of $10 buys
        (m.earlyTokens,) = _buy(0, PURCHASE_INCREMENT, p);
        uint256 supply;
        for (uint256 i; i < 15; i++) {
            (, supply) = _buy(supply, PURCHASE_INCREMENT, p);
        }
        (m.lateTokens,) = _buy(supply, PURCHASE_INCREMENT, p);
        if (m.lateTokens > 0) {
            m.earlyAdvantageBps = (m.earlyTokens * 10_000) / m.lateTokens;
        }
        m.passEarly = m.lateTokens > 0 && m.earlyAdvantageBps >= EARLY_ADVANTAGE_BPS;

        // WhalePriceMove + PostWhalePenalty: $10 x3, then $1000 whale, then $10
        supply = 0;
        (m.firstBuyTokens, supply) = _buy(0, PURCHASE_INCREMENT, p);
        (, supply) = _buy(supply, PURCHASE_INCREMENT, p);
        (, supply) = _buy(supply, PURCHASE_INCREMENT, p);
        m.whalePriceBefore = _calculatePrice(supply, p.shareDivisor, p.coefficient);
        (, supply) = _buy(supply, 1000e18, p);
        m.whalePriceAfter = _calculatePrice(supply, p.shareDivisor, p.coefficient);
        if (m.whalePriceBefore > 0) {
            m.whalePriceMoveBps = (m.whalePriceAfter * 10_000) / m.whalePriceBefore;
        }
        m.passWhale = m.whalePriceMoveBps >= WHALE_PRICE_MOVE_BPS;

        (m.postWhaleTokens,) = _buy(supply, PURCHASE_INCREMENT, p);
        if (m.firstBuyTokens > 0) {
            m.postWhaleTokenBps = (m.postWhaleTokens * 10_000) / m.firstBuyTokens;
        }
        m.passPostWhale = m.firstBuyTokens > 0 && m.postWhaleTokenBps <= POST_WHALE_TOKEN_BPS;

        // CurveEngaged
        m.priceAt100 = _calculatePrice(100e18, p.shareDivisor, p.coefficient);
        m.priceAt100Bps = (m.priceAt100 * 10_000) / BASE_PRICE;
        m.passCurve = m.priceAt100Bps >= CURVE_ENGAGED_BPS;

        // NotTooSteep
        m.passNotTooSteep = m.firstBuyTokens >= MIN_FIRST_BUY_TOKENS;

        // FrontRunCost: $5000 into empty entry
        (m.frontRunTokens,) = _buy(0, 5000e18, p);
        if (m.frontRunTokens > 0) {
            // avgPrice / BASE in bps: (payment * PRICE_PRECISION / tokens) / BASE * 10000
            uint256 avgPrice = (5000e18 * PRICE_PRECISION) / m.frontRunTokens;
            m.frontRunAvgPriceBps = (avgPrice * 10_000) / BASE_PRICE;
        }
        m.passFrontRun = m.frontRunAvgPriceBps >= FRONT_RUN_AVG_PRICE_BPS;

        m.breakevenPurchase = _competitiveBreakevenPurchase(p);

        if (m.passEarly) m.passCount++;
        if (m.passWhale) m.passCount++;
        if (m.passPostWhale) m.passCount++;
        if (m.passCurve) m.passCount++;
        if (m.passNotTooSteep) m.passCount++;
        if (m.passFrontRun) m.passCount++;
    }

    /**
     * @dev Simplified competitive breakeven matching SecondaryPricingBreakeven economics:
     * 5x $20 self-bets + $8.75 subsidy bootstrap pot, then two bettors alternate $10 on entry 1.
     * Returns first purchase number (1-indexed) where net value <= 0, or 0 if none in 40 buys.
     */
    function _competitiveBreakevenPurchase(CurveParams memory p) internal pure returns (uint256) {
        uint256 entrySupply;
        // Bootstrap $20 on entry 1 (self-bet)
        (, entrySupply) = _buy(0, 20e18, p);

        // Aggregate secondary TVL after 5x $20 + $8.75 subsidy
        uint256 pot = 108.75e18;
        uint256 bal1;
        uint256 bal2;

        for (uint256 n = 1; n <= 40; n++) {
            bool isBettor1 = (n % 2 == 1);
            uint256 ownBefore = entrySupply == 0
                ? 0
                : ((isBettor1 ? bal1 : bal2) * 1e18) / entrySupply;

            (uint256 tokens, uint256 newSupply) = _buy(entrySupply, PURCHASE_INCREMENT, p);
            if (tokens == 0) return n;

            if (isBettor1) bal1 += tokens;
            else bal2 += tokens;

            entrySupply = newSupply;
            pot += PURCHASE_INCREMENT;

            uint256 ownAfter = ((isBettor1 ? bal1 : bal2) * 1e18) / entrySupply;
            uint256 ownershipGain = ownAfter > ownBefore ? ownAfter - ownBefore : 0;
            uint256 marginalValue = (ownershipGain * pot) / 1e18;

            if (marginalValue <= PURCHASE_INCREMENT) {
                return n;
            }
        }
        return 0;
    }

    // -------------------------------------------------------------------------
    // Ranking helpers
    // -------------------------------------------------------------------------

    function _better(
        CurveParams memory pa,
        Metrics memory a,
        CurveParams memory pb,
        Metrics memory b,
        bool requireAllPass
    ) internal pure returns (bool) {
        if (requireAllPass) {
            // Prefer keeping production shareDivisor (1e9), then milder open, then later breakeven.
            bool aProd = pa.shareDivisor == 1e9;
            bool bProd = pb.shareDivisor == 1e9;
            if (aProd != bProd) return aProd;
            if (a.firstBuyTokens != b.firstBuyTokens) return a.firstBuyTokens > b.firstBuyTokens;
            uint256 aBe = a.breakevenPurchase == 0 ? type(uint256).max : a.breakevenPurchase;
            uint256 bBe = b.breakevenPurchase == 0 ? type(uint256).max : b.breakevenPurchase;
            if (aBe != bBe) {
                bool aOk = aBe >= 8;
                bool bOk = bBe >= 8;
                if (aOk != bOk) return aOk;
                return aBe > bBe;
            }
            return a.earlyAdvantageBps > b.earlyAdvantageBps;
        }
        if (a.passCount != b.passCount) return a.passCount > b.passCount;
        return a.earlyAdvantageBps > b.earlyAdvantageBps;
    }

    function _insertRanked(
        RankedCandidate[5] memory slot,
        uint256 count,
        CurveParams memory p,
        Metrics memory m,
        bool isBaseline,
        bool requireAllPass
    ) internal pure {
        RankedCandidate memory cand =
            RankedCandidate({params: p, metrics: m, isBaseline: isBaseline});

        uint256 n = count < 5 ? count : 5;
        uint256 insertAt = n;
        for (uint256 i; i < n; i++) {
            if (_better(cand.params, cand.metrics, slot[i].params, slot[i].metrics, requireAllPass)) {
                insertAt = i;
                break;
            }
        }
        if (insertAt >= 5) return;

        uint256 last = n < 5 ? n : 4;
        for (uint256 j = last; j > insertAt; j--) {
            slot[j] = slot[j - 1];
        }
        slot[insertAt] = cand;
    }

    // -------------------------------------------------------------------------
    // Logging
    // -------------------------------------------------------------------------

    function _logCandidate(
        string memory label,
        CurveParams memory p,
        Metrics memory m,
        bool isBaseline
    ) internal pure {
        console.log("---------- %s ----------", label);
        if (isBaseline) console.log("(production SecondaryPricing constants)");
        console.log("shareDivisor=%s  coefficient=%s", p.shareDivisor, p.coefficient);
        console.log("passCount=%s / %s", uint256(m.passCount), METRIC_COUNT);
        console.log("pass Early=%s Whale=%s", m.passEarly ? uint256(1) : uint256(0), m.passWhale ? uint256(1) : uint256(0));
        console.log(
            "pass PostWhale=%s Curve=%s", m.passPostWhale ? uint256(1) : uint256(0), m.passCurve ? uint256(1) : uint256(0)
        );
        console.log(
            "pass NotTooSteep=%s FrontRun=%s",
            m.passNotTooSteep ? uint256(1) : uint256(0),
            m.passFrontRun ? uint256(1) : uint256(0)
        );
        console.log("earlyTokens=%e", m.earlyTokens);
        console.log("lateTokens=%e", m.lateTokens);
        console.log("earlyAdvBps=%s", m.earlyAdvantageBps);
        console.log("whaleMoveBps=%s", m.whalePriceMoveBps);
        console.log("postWhaleTokenBps=%s", m.postWhaleTokenBps);
        console.log("priceAt100Bps=%s", m.priceAt100Bps);
        console.log("firstBuyTokens=%e", m.firstBuyTokens);
        console.log("frontRunAvgPriceBps=%s", m.frontRunAvgPriceBps);
        console.log("breakevenPurchase=%s", m.breakevenPurchase);
    }
}
