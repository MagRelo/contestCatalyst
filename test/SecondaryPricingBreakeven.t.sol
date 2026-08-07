// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/ContestController.sol";
import "../src/SecondaryPricing.sol";
import "./helpers/ReferralTestHarness.sol";
import "solmate/tokens/ERC20.sol";

/**
 * @title BreakEvenAnalysis
 * @dev Settlement-economics simulations (NOT assertion-gated unit tests).
 *
 * Worldview:
 * - Pricing is local (per-entry bonding curve).
 * - Redemption is global (residual secondary TVL merges onto secondaryWinner).
 * - Claimable pot after settle ≈ sideBalance × (1 - subsidyBps) × (1 - referralBps).
 * - Real sizing uses EV ≈ P(win) × ownership × claimablePot − cost.
 *
 * Suites:
 * 1. Sure-winner stress — two bettors duel on Entry 1 with P(win)=1 (curve+fee capacity).
 * 2. P(win)-weighted EV — same path; break-even purchase # for P ∈ {1.0, 0.5, 0.2}.
 * 3. Loser-float merge — capital on other entries funds winner claims after settle.
 * 4. Favorite vs thin — equal $ buys; curve has no P(win) information.
 *
 * Standard settings: PRIMARY_DEPOSIT=$25, subsidyBps=700, referralBps=500, COEFFICIENT=15.
 *
 * Run: forge test --match-path test/SecondaryPricingBreakeven.t.sol -vv
 */
contract BreakEvenAnalysis is ReferralTestHarness {
    ContestController public contest;
    MockERC20 public paymentToken;

    address public operator = address(0x1);
    address public bettor1 = address(0x100);
    address public bettor2 = address(0x200);

    uint256 public constant PRIMARY_DEPOSIT = 25e18;
    uint256 public constant PURCHASE_INCREMENT = 10e18;
    uint256 public constant PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS = 700;

    function setUp() public {
        paymentToken = new MockERC20("Payment Token", "PAY", 18);

        _initReferralInfra(address(paymentToken), operator);
        contest = _createContest(
            PRIMARY_DEPOSIT,
            REFERRAL_NETWORK_BPS,
            block.timestamp + 365 days,
            PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS
        );

        paymentToken.mint(bettor1, 1000000e18);
        paymentToken.mint(bettor2, 1000000e18);

        for (uint256 i = 1; i <= 5; i++) {
            address user = address(uint160(0x10 + i));
            paymentToken.mint(user, 1000e18);

            vm.startPrank(user);
            paymentToken.approve(address(contest), PRIMARY_DEPOSIT + 20e18);
            contest.addPrimaryPosition(i, new bytes32[](0));
            vm.stopPrank();
        }

        vm.prank(operator);
        contest.activateContest();

        for (uint256 i = 1; i <= 5; i++) {
            address user = address(uint160(0x10 + i));
            vm.startPrank(user);
            contest.addSecondaryPosition(i, 20e18, new bytes32[](0));
            vm.stopPrank();
        }
    }

    /**
     * @notice Sure-winner stress: two bettors alternate $10 on Entry 1 with P(win)=1.
     * @dev Conditional on Entry 1 winning — not typical player behavior; measures curve+fee capacity.
     */
    function test_BreakEvenAnalysis() public {
        uint256 entryId = 1;

        console.log("\n=== Sure-Winner Stress: Competitive Betting on Entry 1 (P=1) ===");
        console.log("CONDITIONAL: values assume Entry 1 is secondaryWinner with certainty.");
        console.log("Initial Setup: 5 primary entries ($25 each), each betting $20 on themselves");
        console.log("Two bettors alternate $10 purchases on entry 1\n");

        uint256 initialShares = uint256(contest.netPosition(entryId));
        uint256 initialSideBalance = contest.getSecondarySideBalance();
        uint256 initialPot = _expectedClaimableSecondary(initialSideBalance);

        console.log("Initial State:");
        console.log("  Entry 1 shares: %e", initialShares);
        console.log("  Side balance (backed+subsidy): $%e", initialSideBalance);
        console.log("  Expected claimable pot (loan repay + referral): $%e", initialPot);
        uint256 totalShares = _getTotalShares();
        if (totalShares > 0) {
            console.log("  Entry 1 share of global supply: %e%%\n", (initialShares * 100e18) / totalShares);
        }

        uint256 purchaseCount = 0;
        bool bettor1BreakEven = false;
        bool bettor2BreakEven = false;
        uint256 bettor1Shares = 0;
        uint256 bettor2Shares = 0;

        for (uint256 i = 0; i < 50; i++) {
            uint256 purchaseAmount = PURCHASE_INCREMENT;
            address currentBettor = (i % 2 == 0) ? bettor1 : bettor2;
            string memory bettorLabel = (i % 2 == 0) ? "Bettor 1" : "Bettor 2";

            uint256 sharesBefore = uint256(contest.netPosition(entryId));
            uint256 potBefore = _expectedClaimableSecondary(contest.getSecondarySideBalance());
            uint256 priceBefore = contest.calculateSecondaryPrice(entryId);

            uint256 bettor1OwnershipBefore = sharesBefore > 0 ? (bettor1Shares * 1e18) / sharesBefore : 0;
            uint256 bettor2OwnershipBefore = sharesBefore > 0 ? (bettor2Shares * 1e18) / sharesBefore : 0;

            vm.startPrank(currentBettor);
            paymentToken.approve(address(contest), purchaseAmount);
            uint256 tokensBefore = contest.balanceOf(currentBettor, entryId);
            contest.addSecondaryPosition(entryId, purchaseAmount, new bytes32[](0));
            uint256 tokensAfter = contest.balanceOf(currentBettor, entryId);
            vm.stopPrank();

            uint256 tokensReceived = tokensAfter - tokensBefore;
            if (currentBettor == bettor1) bettor1Shares += tokensReceived;
            else bettor2Shares += tokensReceived;

            uint256 sharesAfter = uint256(contest.netPosition(entryId));
            uint256 potAfter = _expectedClaimableSecondary(contest.getSecondarySideBalance());

            uint256 bettor1OwnershipAfter = sharesAfter > 0 ? (bettor1Shares * 1e18) / sharesAfter : 0;
            uint256 bettor2OwnershipAfter = sharesAfter > 0 ? (bettor2Shares * 1e18) / sharesAfter : 0;

            uint256 purchasingBettorOwnershipBefore =
                (currentBettor == bettor1) ? bettor1OwnershipBefore : bettor2OwnershipBefore;
            uint256 purchasingBettorOwnershipAfter =
                (currentBettor == bettor1) ? bettor1OwnershipAfter : bettor2OwnershipAfter;

            uint256 ownershipIncrease = purchasingBettorOwnershipAfter > purchasingBettorOwnershipBefore
                ? purchasingBettorOwnershipAfter - purchasingBettorOwnershipBefore
                : 0;

            // P(win)=1 sure-winner stress: marginal value = Δownership × claimable pot
            uint256 marginalValue = (ownershipIncrease * potAfter) / 1e18;
            uint256 netValue = marginalValue > purchaseAmount ? marginalValue - purchaseAmount : 0;
            bool isProfitable = marginalValue > purchaseAmount;
            uint256 priceAfter = contest.calculateSecondaryPrice(entryId);

            purchaseCount++;

            console.log("Purchase #%d: %s - $%e", i + 1, bettorLabel, purchaseAmount);
            console.log("  Cost: $%e", purchaseAmount);
            console.log("  Tokens received: %e", tokensReceived);
            console.log("  Price before: %e (%.2f)", priceBefore, _priceToDecimal(priceBefore));
            console.log("  Price after: %e (%.2f)", priceAfter, _priceToDecimal(priceAfter));
            console.log(
                "  Bettor 1 ownership (x10000 pct): %d -> %d",
                _toDecimal(bettor1OwnershipBefore, 4),
                _toDecimal(bettor1OwnershipAfter, 4)
            );
            console.log(
                "  Bettor 2 ownership (x10000 pct): %d -> %d",
                _toDecimal(bettor2OwnershipBefore, 4),
                _toDecimal(bettor2OwnershipAfter, 4)
            );
            console.log("  Claimable pot: $%e -> $%e", potBefore, potAfter);
            console.log("  Marginal value (P=1): $%e", marginalValue);
            console.log("  Net value: $%e", netValue);
            console.log("  Profitable: %s", isProfitable ? "YES" : "NO");

            if (!isProfitable && currentBettor == bettor1 && !bettor1BreakEven) {
                bettor1BreakEven = true;
                console.log("\n*** BETTOR 1 BREAK-EVEN (sure-winner P=1) ***");
                console.log("Purchase #%d", i + 1);
            }
            if (!isProfitable && currentBettor == bettor2 && !bettor2BreakEven) {
                bettor2BreakEven = true;
                console.log("\n*** BETTOR 2 BREAK-EVEN (sure-winner P=1) ***");
                console.log("Purchase #%d", i + 1);
            }
            console.log("");
        }

        console.log("\n=== Summary (sure-winner stress) ===");
        console.log("Total purchases analyzed: %d", purchaseCount);
        console.log("Total wagered on entry 1: $%e", PURCHASE_INCREMENT * purchaseCount);
        uint256 finalSide = contest.getSecondarySideBalance();
        console.log("Final side balance: $%e", finalSide);
        console.log("Final claimable pot: $%e", _expectedClaimableSecondary(finalSide));
        uint256 finalShares = uint256(contest.netPosition(entryId));
        console.log("Final entry 1 shares: %e", finalShares);
        if (finalShares > 0) {
            console.log("Final Bettor 1 ownership (x100 pct): %d", _toDecimal((bettor1Shares * 1e18) / finalShares, 2));
            console.log("Final Bettor 2 ownership (x100 pct): %d", _toDecimal((bettor2Shares * 1e18) / finalShares, 2));
        }
    }

    /**
     * @notice Same duel path; reports first unprofitable purchase under P ∈ {1.0, 0.5, 0.2}.
     * @dev EV = P(win) × Δownership × claimablePot − cost. Break-even moves earlier as P drops.
     */
    function test_BreakEven_PWinWeightedEV() public {
        uint256 entryId = 1;
        uint256[3] memory pBps = [uint256(10_000), 5_000, 2_000]; // 100%, 50%, 20%
        string[3] memory pLabels = ["P=1.00", "P=0.50", "P=0.20"];
        uint256[3] memory breakEvenPurchase; // 0 = none in window
        bool[3] memory found;

        console.log("\n=== P(win)-Weighted EV (same duel path on Entry 1) ===");
        console.log("EV = P(win) * ownershipIncrease * claimablePot - cost");
        console.log("Break-even = first purchase where EV <= 0 for that belief\n");

        uint256 bettor1Shares = 0;
        uint256 bettor2Shares = 0;

        for (uint256 i = 0; i < 40; i++) {
            uint256 purchaseAmount = PURCHASE_INCREMENT;
            address currentBettor = (i % 2 == 0) ? bettor1 : bettor2;

            uint256 sharesBefore = uint256(contest.netPosition(entryId));
            uint256 ownBefore = sharesBefore > 0
                ? ((currentBettor == bettor1 ? bettor1Shares : bettor2Shares) * 1e18) / sharesBefore
                : 0;

            vm.startPrank(currentBettor);
            paymentToken.approve(address(contest), purchaseAmount);
            uint256 tokensBefore = contest.balanceOf(currentBettor, entryId);
            contest.addSecondaryPosition(entryId, purchaseAmount, new bytes32[](0));
            uint256 tokensAfter = contest.balanceOf(currentBettor, entryId);
            vm.stopPrank();

            uint256 tokensReceived = tokensAfter - tokensBefore;
            if (currentBettor == bettor1) bettor1Shares += tokensReceived;
            else bettor2Shares += tokensReceived;

            uint256 sharesAfter = uint256(contest.netPosition(entryId));
            uint256 potAfter = _expectedClaimableSecondary(contest.getSecondarySideBalance());
            uint256 ownAfter = sharesAfter > 0
                ? ((currentBettor == bettor1 ? bettor1Shares : bettor2Shares) * 1e18) / sharesAfter
                : 0;
            uint256 ownershipIncrease = ownAfter > ownBefore ? ownAfter - ownBefore : 0;
            uint256 sureValue = (ownershipIncrease * potAfter) / 1e18;

            console.log("Purchase #%d:", i + 1);
            console.log("  Bettor: %s", currentBettor == bettor1 ? "B1" : "B2");
            console.log("  Tokens: %e", tokensReceived);
            console.log("  OwnGain (bps of 100%): %e", ownershipIncrease);
            console.log("  Claimable pot: $%e", potAfter);
            console.log("  Sure value (P=1): $%e", sureValue);

            for (uint256 p = 0; p < 3; p++) {
                uint256 ev = (sureValue * pBps[p]) / 10_000;
                console.log("  Belief:");
                console.log("    %s", pLabels[p]);
                console.log("    EV: $%e", ev);
                console.log("    Profitable: %s", ev > purchaseAmount ? "YES" : "NO");
                if (!found[p] && ev <= purchaseAmount) {
                    found[p] = true;
                    breakEvenPurchase[p] = i + 1;
                }
            }
            console.log("");
        }

        console.log("=== Break-even purchase # by belief ===");
        for (uint256 p = 0; p < 3; p++) {
            console.log("%s", pLabels[p]);
            if (found[p]) {
                console.log("  first unprofitable purchase: %d", breakEvenPurchase[p]);
            } else {
                console.log("  none within 40 purchases");
            }
        }
    }

    /**
     * @notice Loser-float: capital on other entries funds Entry 1 winner claims after settle.
     */
    function test_LoserFloat_MergedPotClaim() public {
        console.log("\n=== Loser-Float Merge: claim funded by global residual, not local liquidity ===");

        // Extra secondary on entries 2–5 (loser float)
        for (uint256 i = 2; i <= 5; i++) {
            vm.startPrank(bettor2);
            paymentToken.approve(address(contest), 50e18);
            contest.addSecondaryPosition(i, 50e18, new bytes32[](0));
            vm.stopPrank();
        }

        uint256 entry1LocalBefore = contest.secondaryLiquidityPerEntry(1)
            + contest.secondaryPrimarySubsidyPerEntry(1);
        uint256 sideBeforeBuy = contest.getSecondarySideBalance();

        // Bettor1 concentrates $100 on Entry 1
        uint256 buyAmount = 100e18;
        vm.startPrank(bettor1);
        paymentToken.approve(address(contest), buyAmount);
        contest.addSecondaryPosition(1, buyAmount, new bytes32[](0));
        vm.stopPrank();

        uint256 bettor1Shares = contest.balanceOf(bettor1, 1);
        uint256 entry1Supply = uint256(contest.netPosition(1));
        uint256 entry1LocalAfter = contest.secondaryLiquidityPerEntry(1)
            + contest.secondaryPrimarySubsidyPerEntry(1);
        uint256 sideAfter = contest.getSecondarySideBalance();
        uint256 expectedClaimable = _expectedClaimableSecondary(sideAfter);
        uint256 ownership = (bettor1Shares * 1e18) / entry1Supply;
        uint256 expectedClaimIfWins = (ownership * expectedClaimable) / 1e18;

        console.log("Entry 1 local TVL (backed+subsidy): $%e -> $%e", entry1LocalBefore, entry1LocalAfter);
        console.log("Global side balance: $%e -> $%e", sideBeforeBuy, sideAfter);
        console.log("Expected claimable residual (fees): $%e", expectedClaimable);
        console.log("Bettor1 Entry1 ownership: %.4f%%", _toDecimal(ownership, 4));
        console.log("Expected Bettor1 claim if Entry1 wins: $%e", expectedClaimIfWins);
        console.log(
            "Claim vs local Entry1 TVL: claim $%e vs local $%e (claim uses merged pot)",
            expectedClaimIfWins,
            entry1LocalAfter
        );

        // Settle Entry 1 as secondary winner; register referral so fee is paid (not restored)
        address entry1Owner = address(uint160(0x10 + 1));
        address referrer = address(0xBEEF);
        paymentToken.mint(referrer, 1); // ensure referrer can receive
        _registerWinnerReferrer(entry1Owner, referrer);

        uint256[] memory winners = new uint256[](1);
        winners[0] = 1;
        uint256[] memory bps = new uint256[](1);
        bps[0] = 10_000;
        _settleContest(contest, winners, bps, 1);

        uint256 winnerPool = contest.secondaryLiquidityPerEntry(1);
        uint256 balBefore = paymentToken.balanceOf(bettor1);
        vm.prank(bettor1);
        contest.claimSecondaryPayout(1);
        uint256 claimed = paymentToken.balanceOf(bettor1) - balBefore;

        console.log("\nAfter settle (Entry 1 = secondaryWinner):");
        console.log("  Winner pool before claim: $%e", winnerPool);
        console.log("  Bettor1 actual claim: $%e", claimed);
        console.log("  Expected claim (pre-settle estimate): $%e", expectedClaimIfWins);
        console.log("  Local Entry1 TVL at buy time was only: $%e", entry1LocalAfter);
        console.log("  Loser-float proves claim >> local liquidity alone when other entries hold TVL.");
    }

    /**
     * @notice Favorite vs thin: equal $ buys mint different share amounts; curve ignores P(win).
     */
    function test_FavoriteVsThin_EqualDollarBuy() public {
        console.log("\n=== Favorite vs Thin: equal $ buy (curve has no P(win) info) ===");

        // Thicken Entry 1 with $500 of secondary volume
        vm.startPrank(bettor2);
        paymentToken.approve(address(contest), 500e18);
        contest.addSecondaryPosition(1, 500e18, new bytes32[](0));
        vm.stopPrank();

        uint256 thickPrice = contest.calculateSecondaryPrice(1);
        uint256 thinPrice = contest.calculateSecondaryPrice(2);
        uint256 thickSupply = uint256(contest.netPosition(1));
        uint256 thinSupply = uint256(contest.netPosition(2));

        console.log("Pre-buy: Entry1 (favorite) supply=%e price=%e", thickSupply, thickPrice);
        console.log("Pre-buy: Entry2 (thin)     supply=%e price=%e", thinSupply, thinPrice);

        uint256 buyAmount = 50e18;
        uint256 sideBefore = contest.getSecondarySideBalance();

        vm.startPrank(bettor1);
        paymentToken.approve(address(contest), buyAmount * 2);
        uint256 t1Before = contest.balanceOf(bettor1, 1);
        contest.addSecondaryPosition(1, buyAmount, new bytes32[](0));
        uint256 thickTokens = contest.balanceOf(bettor1, 1) - t1Before;

        uint256 t2Before = contest.balanceOf(bettor1, 2);
        contest.addSecondaryPosition(2, buyAmount, new bytes32[](0));
        uint256 thinTokens = contest.balanceOf(bettor1, 2) - t2Before;
        vm.stopPrank();

        uint256 sideAfter = contest.getSecondarySideBalance();
        uint256 claimable = _expectedClaimableSecondary(sideAfter);
        uint256 thickOwn = (thickTokens * 1e18) / uint256(contest.netPosition(1));
        uint256 thinOwn = (thinTokens * 1e18) / uint256(contest.netPosition(2));
        uint256 claimIfThickWins = (thickOwn * claimable) / 1e18;
        uint256 claimIfThinWins = (thinOwn * claimable) / 1e18;

        console.log("\nEqual $%e buys:", buyAmount);
        console.log("  Favorite tokens minted: %e (ownership %.4f%%)", thickTokens, _toDecimal(thickOwn, 4));
        console.log("  Thin tokens minted:     %e (ownership %.4f%%)", thinTokens, _toDecimal(thinOwn, 4));
        console.log("  Token ratio thin/fav:   %e", (thinTokens * 1e18) / thickTokens);
        console.log("  Side balance: $%e -> $%e", sideBefore, sideAfter);
        console.log("  Claimable residual: $%e", claimable);
        console.log("  Conditional claim if favorite wins: $%e", claimIfThickWins);
        console.log("  Conditional claim if thin wins:     $%e", claimIfThinWins);
        console.log("NOTE: Thin buys more ownership per $; that is curve supply, not implied win probability.");
    }

    /// @dev Expected secondary claim TVL after loan repay and referral haircut (matches settle netSecondary path).
    function _expectedClaimableSecondary(uint256 sideBalance) internal pure returns (uint256) {
        uint256 afterLoan = (sideBalance * (10_000 - PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS)) / 10_000;
        return (afterLoan * (10_000 - REFERRAL_NETWORK_BPS)) / 10_000;
    }

    function _getTotalShares() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= 5; i++) {
            int256 pos = contest.netPosition(i);
            if (pos > 0) total += uint256(pos);
        }
        return total;
    }

    function _priceToDecimal(uint256 price) internal pure returns (uint256) {
        return price / 1e4;
    }

    function _toDecimal(uint256 value, uint256 decimals) internal pure returns (uint256) {
        if (decimals == 4) return value / 1e14;
        return value / 1e16;
    }
}

/**
 * @title MockERC20
 * @dev Simple ERC20 token for testing
 */
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
