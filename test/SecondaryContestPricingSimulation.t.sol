// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ContestController.sol";
import "../src/ContestFactory.sol";
import "solmate/tokens/ERC20.sol";

/**
 * @title SecondaryContestPricingTest
 * @author MagRelo
 * @dev SIMULATION TESTS - These are NOT assertion-based unit tests
 * 
 * IMPORTANT: These tests simulate real-world buying patterns to observe how the pricing
 * mechanism behaves in practice. They do NOT contain assertions that must pass. The purpose
 * is to run these scenarios and examine the console output to verify that the pricing:
 * - Meets human intuition for fairness
 * - Passes the "smell test" for reasonable behavior
 * - Provides appropriate advantages to early bettors
 * - Protects against whale manipulation while still allowing large purchases
 * 
 * Contest Settings:
 * - Oracle fee: 5% (500 bps)
 * - Position bonus: 5% (500 bps) - goes to entry owner
 * - Target primary share: 30% (3000 bps)
 * - Max cross-subsidy: 15% (1500 bps)
 * 
 * These settings mean more collateral per deposit (better value for buyers) compared to
 * previous settings with higher position bonuses. The pricing algorithm (polynomial bonding
 * curve) remains unchanged, so qualitative behaviors are the same.
 * 
 * Run with `forge test --match-path test/SecondaryContestPricingSimulation.t.sol -vv` to see console output
 * and manually review whether the pricing behavior feels fair and intuitive.
 * 
 * NOTE: When updating documentation, run tests with verbose mode and capture all logs:
 *   forge test --match-path test/SecondaryContestPricingSimulation.t.sol -vvv > test_output.txt
 * Then format the output into tables showing purchase size, percentage of total shares,
 * price change, price (before/after), and price per share (amount spent / tokens received)
 * for each scenario. Write these tables to PRICING.md.
 * 
 * This test file illustrates 6 scenarios:
 * 1. Sequential equal purchases - price increases with each purchase
 * 2. Mixed purchase sizes - large purchases move price significantly
 * 3. Multiple entries competition - how prices change across entries
 * 4. Early vs late purchases - early users get more tokens
 * 5. Whale purchase impact - single large purchase dramatically affects pricing
 * 6. Early buyers maintain percentage share - early buyers not crowded out by whales
 */
contract SecondaryContestPricingTest is Test {
    ContestFactory public factory;
    ContestController public contest;
    MockERC20 public paymentToken;
    
    address public oracle = address(0x1);
    address public user1 = address(0x10);
    address public user2 = address(0x20);
    address public user3 = address(0x30);
    address public user4 = address(0x40);
    address public user5 = address(0x50);
    address public whale = address(0x100);
    
    uint256 public constant PRIMARY_DEPOSIT = 25e18; // $25 (recommended for typical contests)
    
    struct PurchaseResult {
        uint256 amountSpent;
        uint256 tokensReceived;
        uint256 priceBefore;
        uint256 priceAfter;
        uint256 totalSupplyBefore;
        uint256 totalSupplyAfter;
    }
    
    function setUp() public {
        // Deploy mock ERC20 token
        paymentToken = new MockERC20("Payment Token", "PAY", 18);
        
        // Deploy factory
        factory = new ContestFactory();
        
        // Create contest
        address contestAddress = factory.createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            500, // 5% oracle fee
            block.timestamp + 365 days,
            500, // positionBonusShareBps: 5%
            3000, // targetPrimaryShareBps: 30%
            1500  // maxCrossSubsidyBps: 15%
        );
        
        contest = ContestController(contestAddress);
        
        // Fund users
        paymentToken.mint(user1, 100000e18);
        paymentToken.mint(user2, 100000e18);
        paymentToken.mint(user3, 100000e18);
        paymentToken.mint(user4, 100000e18);
        paymentToken.mint(user5, 100000e18);
        paymentToken.mint(whale, 1000000e18);
        
        // Create primary entries (needed for secondary market)
        vm.startPrank(user1);
        paymentToken.approve(address(contest), PRIMARY_DEPOSIT);
        contest.addPrimaryPosition(1, new bytes32[](0));
        vm.stopPrank();
        
        vm.startPrank(user2);
        paymentToken.approve(address(contest), PRIMARY_DEPOSIT);
        contest.addPrimaryPosition(2, new bytes32[](0));
        vm.stopPrank();
        
        vm.startPrank(user3);
        paymentToken.approve(address(contest), PRIMARY_DEPOSIT);
        contest.addPrimaryPosition(3, new bytes32[](0));
        vm.stopPrank();
    }
    
    /**
     * @notice Scenario 1: Sequential Equal Purchases
     * Story: Three users each purchase $10 worth of shares on entry 1
     * Expected: Each subsequent purchase gets fewer tokens as price increases
     */
    function test_Scenario1_SequentialEqualPurchases() public {
        uint256 purchaseAmount = 10e18; // $10
        
        console.log("\n=== Scenario 1: Sequential Equal Purchases ===");
        console.log("Story: Three users each purchase $10 worth of shares on entry 1");
        console.log("Expected: Each subsequent purchase gets fewer tokens as price increases\n");
        
        PurchaseResult[] memory results = new PurchaseResult[](3);
        
        // User 1 purchases $10
        results[0] = _makePurchase(user1, 1, purchaseAmount, "User 1");
        
        // User 2 purchases $10
        results[1] = _makePurchase(user2, 1, purchaseAmount, "User 2");
        
        // User 3 purchases $10
        results[2] = _makePurchase(user3, 1, purchaseAmount, "User 3");
        
        uint256 totalPriceIncrease = (results[2].priceAfter * 1e18) / results[0].priceBefore;
        uint256 priceIncInt = totalPriceIncrease / 1e18;
        uint256 priceIncFrac = (totalPriceIncrease % 1e18) / 1e16;
        
        uint256 user2Ratio = (results[0].tokensReceived * 1e18) / results[1].tokensReceived;
        uint256 user2RatioInt = user2Ratio / 1e18;
        uint256 user2RatioFrac = (user2Ratio % 1e18) / 1e16;
        
        uint256 user3Ratio = (results[0].tokensReceived * 1e18) / results[2].tokensReceived;
        uint256 user3RatioInt = user3Ratio / 1e18;
        uint256 user3RatioFrac = (user3Ratio % 1e18) / 1e16;
        
        console.log("\nSummary:");
        console.log("- User 1 (first):  %e tokens at price %e", results[0].tokensReceived, results[0].priceBefore);
        console.log("- User 2 (second): %e tokens at price %e", results[1].tokensReceived, results[1].priceBefore);
        console.log("- User 3 (third):  %e tokens at price %e", results[2].tokensReceived, results[2].priceBefore);
        console.log("- Price increased from %e to %e", results[0].priceBefore, results[2].priceAfter);
        console.log("- Price multiplier: %d.%d", priceIncInt, priceIncFrac);
        console.log("- User 2 got %d.%d fewer tokens than User 1", user2RatioInt, user2RatioFrac);
        console.log("- User 3 got %d.%d fewer tokens than User 1", user3RatioInt, user3RatioFrac);
    }
    
    /**
     * @notice Scenario 2: Mixed Purchase Sizes
     * Story: User 1 purchases $10, User 2 (whale) purchases $1000, User 3 purchases $10
     * Expected: Large purchase moves price significantly, small purchase after gets very few tokens
     */
    function test_Scenario2_MixedPurchaseSizes() public {
        console.log("\n=== Scenario 2: Mixed Purchase Sizes ===");
        console.log("Story: User 1 purchases $10, Whale purchases $1000, User 3 purchases $10");
        console.log("Expected: Large purchase moves price significantly\n");
        
        PurchaseResult memory result1 = _makePurchase(user1, 1, 10e18, "User 1 ($10)");
        PurchaseResult memory result2 = _makePurchase(whale, 1, 1000e18, "Whale ($1000)");
        PurchaseResult memory result3 = _makePurchase(user3, 1, 10e18, "User 3 ($10)");
        
        uint256 priceIncrease = result2.priceAfter - result2.priceBefore;
        uint256 priceIncreasePercent = (priceIncrease * 10000) / result2.priceBefore;
        
        console.log("\nSummary:");
        console.log("- User 1:  %e tokens at price %e", result1.tokensReceived, result1.priceBefore);
        console.log("- Whale:   %e tokens at price %e (price jumped to %e)", 
            result2.tokensReceived, result2.priceBefore, result2.priceAfter);
        console.log("- User 3:  %e tokens at price %e", result3.tokensReceived, result3.priceBefore);
        uint256 priceIncreasePercentInt = priceIncreasePercent / 100;
        uint256 priceIncreasePercentFrac = priceIncreasePercent % 100;
        uint256 whaleRatio = (result2.tokensReceived * 1e18) / result1.tokensReceived;
        uint256 whaleRatioInt = whaleRatio / 1e18;
        uint256 whaleRatioFrac = (whaleRatio % 1e18) / 1e16; // 2 decimal places (scale down by 100)
        
        console.log("- Price increased %d.%d%% (%d basis points) after whale purchase", 
            priceIncreasePercentInt, priceIncreasePercentFrac, priceIncreasePercent);
        console.log("- Whale received %d.%d more tokens than User 1", 
            whaleRatioInt, whaleRatioFrac);
    }
    
    /**
     * @notice Scenario 3: Multiple Entries Competition
     * Story: Users purchase on different entries, showing how prices balance
     * Expected: Popular entry (more purchases) has higher price
     */
    function test_Scenario3_MultipleEntriesCompetition() public {
        console.log("\n=== Scenario 3: Multiple Entries Competition ===");
        console.log("Story: Users purchase on different entries");
        console.log("Expected: Popular entry (more purchases) has higher price\n");
        
        // Initial purchases on entry 1
        _makePurchase(user1, 1, 10e18, "User 1 on Entry 1");
        _makePurchase(user2, 1, 10e18, "User 2 on Entry 1");
        
        // Purchases on entry 2
        _makePurchase(user3, 2, 10e18, "User 3 on Entry 2");
        
        // More purchases on entry 1
        _makePurchase(user4, 1, 10e18, "User 4 on Entry 1");
        
        // Check prices
        uint256 price1 = contest.calculateSecondaryPrice(1);
        uint256 price2 = contest.calculateSecondaryPrice(2);
        uint256 price3 = contest.calculateSecondaryPrice(3);
        
        uint256 priceRatio12 = (price1 * 1e18) / price2;
        uint256 priceRatio12Int = priceRatio12 / 1e18;
        uint256 priceRatio12Frac = (priceRatio12 % 1e18) / 1e16;
        
        uint256 priceRatio13 = (price1 * 1e18) / price3;
        uint256 priceRatio13Int = priceRatio13 / 1e18;
        uint256 priceRatio13Frac = (priceRatio13 % 1e18) / 1e16;
        
        console.log("\nSummary:");
        console.log("- Entry 1 price: %e (3 purchases)", price1);
        console.log("- Entry 2 price: %e (1 purchase)", price2);
        console.log("- Entry 3 price: %e (0 purchases)", price3);
        console.log("- Entry 1 is %d.%d more expensive than Entry 2", 
            priceRatio12Int, priceRatio12Frac);
        console.log("- Entry 1 is %d.%d more expensive than Entry 3", 
            priceRatio13Int, priceRatio13Frac);
    }
    
    /**
     * @notice Scenario 4: Early vs Late Purchases
     * Story: User 1 purchases early, then many users purchase, then User 1 purchases again
     * Expected: Early purchase gets many tokens, late purchase gets few tokens
     */
    function test_Scenario4_EarlyVsLatePurchases() public {
        console.log("\n=== Scenario 4: Early vs Late Purchases ===");
        console.log("Story: User 1 purchases early, then many users purchase, then User 1 purchases again");
        console.log("Expected: Early purchase gets many tokens, late purchase gets few tokens\n");
        
        // User 1 early purchase
        PurchaseResult memory early = _makePurchase(user1, 1, 100e18, "User 1 (Early - $100)");
        
        // Many users purchase (simulating market activity)
        for (uint i = 0; i < 10; i++) {
            address user = address(uint160(0x1000 + i));
            paymentToken.mint(user, 1000e18);
            vm.startPrank(user);
            paymentToken.approve(address(contest), 1000e18);
            contest.addSecondaryPosition(1, 50e18, new bytes32[](0));
            vm.stopPrank();
        }
        
        // User 1 late purchase (same amount)
        PurchaseResult memory late = _makePurchase(user1, 1, 100e18, "User 1 (Late - $100)");
        
        uint256 earlyVsLateRatio = (early.tokensReceived * 1e18) / late.tokensReceived;
        uint256 earlyVsLateInt = earlyVsLateRatio / 1e18;
        uint256 earlyVsLateFrac = (earlyVsLateRatio % 1e18) / 1e16;
        
        uint256 priceIncreaseRatio = (late.priceAfter * 1e18) / early.priceBefore;
        uint256 priceIncRatioInt = priceIncreaseRatio / 1e18;
        uint256 priceIncRatioFrac = (priceIncreaseRatio % 1e18) / 1e16;
        
        console.log("\nSummary:");
        console.log("- Early purchase:  %e tokens at price %e", early.tokensReceived, early.priceBefore);
        console.log("- Late purchase:   %e tokens at price %e", late.tokensReceived, late.priceBefore);
        console.log("- Early got %d.%d more tokens than late", 
            earlyVsLateInt, earlyVsLateFrac);
        console.log("- Price increased from %e to %e", early.priceBefore, late.priceAfter);
        console.log("- Price multiplier: %d.%d", priceIncRatioInt, priceIncRatioFrac);
    }
    
    /**
     * @notice Scenario 5: Whale Purchase Impact
     * Story: Small purchases establish baseline, then whale makes massive purchase
     * Expected: Whale purchase dramatically increases price, subsequent small purchases get very few tokens
     */
    function test_Scenario5_WhalePurchaseImpact() public {
        console.log("\n=== Scenario 5: Whale Purchase Impact ===");
        console.log("Story: Small purchases establish baseline, then whale makes massive purchase");
        console.log("Expected: Whale purchase dramatically increases price\n");
        
        // Establish baseline with small purchases
        PurchaseResult memory baseline1 = _makePurchase(user1, 1, 10e18, "User 1 ($10)");
        _makePurchase(user2, 1, 10e18, "User 2 ($10)");
        _makePurchase(user3, 1, 10e18, "User 3 ($10)");
        
        uint256 priceBeforeWhale = contest.calculateSecondaryPrice(1);
        
        // Whale makes massive purchase
        PurchaseResult memory whalePurchase = _makePurchase(whale, 1, 10000e18, "Whale ($10,000)");
        
        uint256 priceAfterWhale = contest.calculateSecondaryPrice(1);
        
        // Small purchase after whale
        PurchaseResult memory afterWhale = _makePurchase(user4, 1, 10e18, "User 4 ($10 after whale)");
        
        uint256 priceMultiplier = (priceAfterWhale * 1e18) / priceBeforeWhale;
        
        uint256 whaleVsBaselineRatio = (whalePurchase.tokensReceived * 1e18) / baseline1.tokensReceived;
        uint256 whaleVsBaselineInt = whaleVsBaselineRatio / 1e18;
        uint256 whaleVsBaselineFrac = (whaleVsBaselineRatio % 1e18) / 1e16;
        
        uint256 baselineVsAfterRatio = (baseline1.tokensReceived * 1e18) / afterWhale.tokensReceived;
        uint256 baselineVsAfterInt = baselineVsAfterRatio / 1e18;
        uint256 baselineVsAfterFrac = (baselineVsAfterRatio % 1e18) / 1e16;
        
        uint256 priceMultInt = priceMultiplier / 1e18;
        uint256 priceMultFrac = (priceMultiplier % 1e18) / 1e16;
        
        console.log("\nSummary:");
        console.log("- Baseline price: %e", priceBeforeWhale);
        console.log("- After whale:    %e", priceAfterWhale);
        console.log("- Price multiplier: %d.%d", priceMultInt, priceMultFrac);
        console.log("- Whale received: %e tokens", whalePurchase.tokensReceived);
        console.log("- Whale got %d.%d more tokens than baseline", 
            whaleVsBaselineInt, whaleVsBaselineFrac);
        console.log("- User 4 received: %e tokens", afterWhale.tokensReceived);
        console.log("- User 4 got %d.%d fewer tokens than baseline", 
            baselineVsAfterInt, baselineVsAfterFrac);
    }
    
    /**
     * @notice Scenario 6: Early Buyers Maintain Percentage Share
     * Story: Early buyers purchase, then whale makes large purchase
     * Expected: Early buyers maintain their percentage share (not crowded out)
     */
    function test_Scenario6_EarlyBuyersMaintainShare() public {
        console.log("\n=== Scenario 6: Early Buyers Maintain Percentage Share ===");
        console.log("Story: Early buyers purchase, then whale makes large purchase");
        console.log("Expected: Early buyers maintain their percentage share\n");
        
        // Early buyers purchase
        PurchaseResult memory early1 = _makePurchase(user1, 1, 100e18, "Early Buyer 1 ($100)");
        PurchaseResult memory early2 = _makePurchase(user2, 1, 100e18, "Early Buyer 2 ($100)");
        
        uint256 totalSupplyBeforeWhale = uint256(contest.netPosition(1));
        uint256 early1ShareBefore = (early1.tokensReceived * 1e18) / totalSupplyBeforeWhale;
        uint256 early2ShareBefore = (early2.tokensReceived * 1e18) / totalSupplyBeforeWhale;
        
        console.log("- Total supply before whale: %e", totalSupplyBeforeWhale);
        console.log("- Early 1 share before: %e%%", early1ShareBefore / 1e16);
        console.log("- Early 2 share before: %e%%", early2ShareBefore / 1e16);
        
        // Whale makes large purchase (price increases during purchase)
        _makePurchase(whale, 1, 10000e18, "Whale ($10,000)");
        
        uint256 totalSupplyAfterWhale = uint256(contest.netPosition(1));
        uint256 early1ShareAfter = (early1.tokensReceived * 1e18) / totalSupplyAfterWhale;
        uint256 early2ShareAfter = (early2.tokensReceived * 1e18) / totalSupplyAfterWhale;
        
        console.log("- Total supply after whale: %e", totalSupplyAfterWhale);
        console.log("- Early 1 share after: %e%%", early1ShareAfter / 1e16);
        console.log("- Early 2 share after: %e%%", early2ShareAfter / 1e16);
        
        uint256 shareDiff1 = early1ShareAfter > early1ShareBefore 
            ? early1ShareAfter - early1ShareBefore 
            : early1ShareBefore - early1ShareAfter;
        uint256 shareDiff2 = early2ShareAfter > early2ShareBefore 
            ? early2ShareAfter - early2ShareBefore 
            : early2ShareBefore - early2ShareAfter;
        
        console.log("- Early buyer 1 share change: %e%%", shareDiff1 / 1e16);
        console.log("- Early buyer 2 share change: %e%%", shareDiff2 / 1e16);
        console.log("- Review whether early buyers maintained reasonable share percentage");
    }
    
    // ============ Helper Functions ============
    
    function _makePurchase(
        address user,
        uint256 entryId,
        uint256 amount,
        string memory label
    ) internal returns (PurchaseResult memory result) {
        uint256 priceBefore = contest.calculateSecondaryPrice(entryId);
        uint256 totalSupplyBefore = uint256(contest.netPosition(entryId));
        
        vm.startPrank(user);
        paymentToken.approve(address(contest), amount);
        uint256 balanceBefore = paymentToken.balanceOf(user);
        uint256 tokensBefore = contest.balanceOf(user, entryId);
        
        contest.addSecondaryPosition(entryId, amount, new bytes32[](0));
        
        uint256 balanceAfter = paymentToken.balanceOf(user);
        uint256 tokensAfter = contest.balanceOf(user, entryId);
        vm.stopPrank();
        
        uint256 priceAfter = contest.calculateSecondaryPrice(entryId);
        uint256 totalSupplyAfter = uint256(contest.netPosition(entryId));
        
        result = PurchaseResult({
            amountSpent: balanceBefore - balanceAfter,
            tokensReceived: tokensAfter - tokensBefore,
            priceBefore: priceBefore,
            priceAfter: priceAfter,
            totalSupplyBefore: totalSupplyBefore,
            totalSupplyAfter: totalSupplyAfter
        });
        
        uint256 priceChangeBps = ((result.priceAfter - result.priceBefore) * 10000) / result.priceBefore;
        uint256 priceChangePercent = priceChangeBps / 100; // Convert bps to percent (integer part)
        uint256 priceChangePercentFrac = priceChangeBps % 100; // Fractional part (0-99)
        
        // Calculate price per share (effective price paid: amount spent / tokens received)
        // Convert to PRICE_PRECISION units to match price units
        uint256 pricePerShare = result.tokensReceived > 0 
            ? (result.amountSpent * 1e6) / result.tokensReceived 
            : 0;
        
        console.log("%s:", label);
        console.log("  Amount spent:    %e", result.amountSpent);
        console.log("  Tokens received: %e", result.tokensReceived);
        console.log("  Price before:    %e", result.priceBefore);
        console.log("  Price after:     %e", result.priceAfter);
        console.log("  Price change:    %d.%d%% (%d basis points)", 
            priceChangePercent, priceChangePercentFrac, priceChangeBps);
        console.log("  Price per share: %e", pricePerShare);
        console.log("  Total supply:   %e -> %e", result.totalSupplyBefore, result.totalSupplyAfter);
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
