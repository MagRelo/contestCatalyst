// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ContestController.sol";
import "../src/ContestFactory.sol";
import "../src/SecondaryPricing.sol";
import "solmate/tokens/ERC20.sol";

/**
 * @title BreakEvenAnalysis
 * @dev Simulation to analyze when pricing becomes prohibitive for additional betting
 * 
 * This simulation:
 * 1. Sets up 5 entries with $100 bet on each
 * 2. Simulates sequential purchases on entry 1
 * 3. Calculates break-even economics at each step
 * 4. Identifies when marginal cost exceeds marginal value
 * 
 * Run with: forge test --match-path test/BreakEvenAnalysis.t.sol -vv
 */
contract BreakEvenAnalysis is Test {
    ContestFactory public factory;
    ContestController public contest;
    MockERC20 public paymentToken;
    
    address public oracle = address(0x1);
    address public bettor1 = address(0x100); // First bettor competing for ownership
    address public bettor2 = address(0x200); // Second bettor competing for ownership
    
    uint256 public constant PRIMARY_DEPOSIT = 25e18; // $25
    uint256 public constant PURCHASE_INCREMENT = 10e18; // $10 increments for analysis
    
    struct BreakEvenData {
        uint256 purchaseNumber;
        address bettor; // Which bettor made this purchase
        uint256 purchaseAmount;
        uint256 cost;
        uint256 tokensReceived;
        uint256 totalSharesBefore;
        uint256 totalSharesAfter;
        uint256 bettor1OwnershipBefore; // percentage (scaled by 1e18)
        uint256 bettor1OwnershipAfter;
        uint256 bettor2OwnershipBefore;
        uint256 bettor2OwnershipAfter;
        uint256 potSizeBefore;
        uint256 potSizeAfter;
        uint256 marginalValue; // (ownershipAfter - ownershipBefore) * potSizeAfter
        uint256 netValue; // marginalValue - cost
        uint256 priceBefore;
        uint256 priceAfter;
        bool isProfitable;
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
        
        // Fund both bettors
        paymentToken.mint(bettor1, 1000000e18); // $1M for testing
        paymentToken.mint(bettor2, 1000000e18); // $1M for testing
        
        // Create 5 primary entries, each also betting $20 on themselves in secondary
        for (uint256 i = 1; i <= 5; i++) {
            address user = address(uint160(0x10 + i));
            paymentToken.mint(user, 1000e18);
            
            vm.startPrank(user);
            paymentToken.approve(address(contest), PRIMARY_DEPOSIT + 20e18);
            contest.addPrimaryPosition(i, new bytes32[](0));
            // Each primary entry bets $20 on themselves in secondary
            contest.addSecondaryPosition(i, 20e18, new bytes32[](0));
            vm.stopPrank();
        }
    }
    
    /**
     * @notice Simulate additional betting on entry 1 and analyze break-even economics
     */
    function test_BreakEvenAnalysis() public {
        uint256 entryId = 1; // Focus on entry 1
        
        console.log("\n=== Break-Even Analysis: Competitive Betting on Entry 1 ===");
        console.log("Initial Setup: 5 primary entries ($25 each), each betting $20 on themselves");
        console.log("Two bettors alternate $10 purchases on entry 1, competing for ownership\n");
        
        // Get initial state
        uint256 initialShares = uint256(contest.netPosition(entryId));
        uint256 initialPot = contest.getSecondarySideBalance();
        
        console.log("Initial State:");
        console.log("  Entry 1 shares: %e", initialShares);
        console.log("  Total pot: $%e", initialPot);
        uint256 totalShares = _getTotalShares();
        if (totalShares > 0) {
            console.log("  Entry 1 ownership: %e%%\n", 
                (initialShares * 100e18) / totalShares);
        } else {
            console.log("  Entry 1 ownership: 0%% (no secondary bets yet)\n");
        }
        
        BreakEvenData[] memory results = new BreakEvenData[](50); // Max 50 purchases
        uint256 purchaseCount = 0;
        bool bettor1BreakEven = false;
        bool bettor2BreakEven = false;
        
        // Track both bettors' cumulative shares
        uint256 bettor1Shares = 0;
        uint256 bettor2Shares = 0;
        
        for (uint256 i = 0; i < 50; i++) {
            uint256 purchaseAmount = PURCHASE_INCREMENT;
            
            // Alternate between bettor1 and bettor2 (bettor1 goes first on odd purchases)
            address currentBettor = (i % 2 == 0) ? bettor1 : bettor2;
            string memory bettorLabel = (i % 2 == 0) ? "Bettor 1" : "Bettor 2";
            
            // Get state before purchase
            uint256 sharesBefore = uint256(contest.netPosition(entryId));
            uint256 potBefore = contest.getSecondarySideBalance();
            uint256 priceBefore = contest.calculateSecondaryPrice(entryId);
            
            // Calculate ownership for both bettors before purchase
            uint256 bettor1OwnershipBefore = sharesBefore > 0 
                ? (bettor1Shares * 1e18) / sharesBefore 
                : 0;
            uint256 bettor2OwnershipBefore = sharesBefore > 0 
                ? (bettor2Shares * 1e18) / sharesBefore 
                : 0;
            
            // Make purchase
            vm.startPrank(currentBettor);
            paymentToken.approve(address(contest), purchaseAmount);
            uint256 tokensBefore = contest.balanceOf(currentBettor, entryId);
            contest.addSecondaryPosition(entryId, purchaseAmount, new bytes32[](0));
            uint256 tokensAfter = contest.balanceOf(currentBettor, entryId);
            vm.stopPrank();
            
            uint256 tokensReceived = tokensAfter - tokensBefore;
            
            // Update shares for the purchasing bettor
            if (currentBettor == bettor1) {
                bettor1Shares += tokensReceived;
            } else {
                bettor2Shares += tokensReceived;
            }
            
            // Get state after purchase
            uint256 sharesAfter = uint256(contest.netPosition(entryId));
            uint256 potAfter = contest.getSecondarySideBalance();
            
            // Calculate ownership for both bettors after purchase
            uint256 bettor1OwnershipAfter = sharesAfter > 0 
                ? (bettor1Shares * 1e18) / sharesAfter 
                : 0;
            uint256 bettor2OwnershipAfter = sharesAfter > 0 
                ? (bettor2Shares * 1e18) / sharesAfter 
                : 0;
            
            // Calculate break-even metrics for the purchasing bettor
            uint256 purchasingBettorOwnershipBefore = (currentBettor == bettor1) 
                ? bettor1OwnershipBefore 
                : bettor2OwnershipBefore;
            uint256 purchasingBettorOwnershipAfter = (currentBettor == bettor1) 
                ? bettor1OwnershipAfter 
                : bettor2OwnershipAfter;
            
            uint256 ownershipIncrease = purchasingBettorOwnershipAfter > purchasingBettorOwnershipBefore
                ? purchasingBettorOwnershipAfter - purchasingBettorOwnershipBefore
                : 0;
            
            // Marginal value = ownership increase * pot size (after purchase)
            uint256 marginalValue = (ownershipIncrease * potAfter) / 1e18;
            
            // Net value = marginal value - cost (positive = profitable)
            uint256 netValue = marginalValue > purchaseAmount 
                ? marginalValue - purchaseAmount 
                : 0;
            
            // Profitable if marginal value exceeds cost
            bool isProfitable = marginalValue > purchaseAmount;
            
            uint256 priceAfter = contest.calculateSecondaryPrice(entryId);
            
            results[purchaseCount] = BreakEvenData({
                purchaseNumber: i + 1,
                bettor: currentBettor,
                purchaseAmount: purchaseAmount,
                cost: purchaseAmount,
                tokensReceived: tokensReceived,
                totalSharesBefore: sharesBefore,
                totalSharesAfter: sharesAfter,
                bettor1OwnershipBefore: bettor1OwnershipBefore,
                bettor1OwnershipAfter: bettor1OwnershipAfter,
                bettor2OwnershipBefore: bettor2OwnershipBefore,
                bettor2OwnershipAfter: bettor2OwnershipAfter,
                potSizeBefore: potBefore,
                potSizeAfter: potAfter,
                marginalValue: marginalValue,
                netValue: netValue,
                priceBefore: priceBefore,
                priceAfter: priceAfter,
                isProfitable: isProfitable
            });
            
            purchaseCount++;
            
            // Log this purchase
            console.log("Purchase #%d: %s - $%e", i + 1, bettorLabel, purchaseAmount);
            console.log("  Cost: $%e", purchaseAmount);
            console.log("  Tokens received: %e", tokensReceived);
            console.log("  Price before: %e (%.2f)", priceBefore, _priceToDecimal(priceBefore));
            console.log("  Price after: %e (%.2f)", priceAfter, _priceToDecimal(priceAfter));
            console.log("  Bettor 1 ownership: %.4f%% -> %.4f%%", 
                _toDecimal(bettor1OwnershipBefore, 4),
                _toDecimal(bettor1OwnershipAfter, 4));
            console.log("  Bettor 2 ownership: %.4f%% -> %.4f%%", 
                _toDecimal(bettor2OwnershipBefore, 4),
                _toDecimal(bettor2OwnershipAfter, 4));
            console.log("  Pot size: $%e -> $%e", potBefore, potAfter);
            console.log("  Marginal value: $%e", marginalValue);
            console.log("  Net value: $%e", netValue);
            console.log("  Profitable: %s", isProfitable ? "YES" : "NO");
            
            // Track break-even for each bettor
            if (!isProfitable && currentBettor == bettor1 && !bettor1BreakEven) {
                bettor1BreakEven = true;
                console.log("\n*** BETTOR 1 BREAK-EVEN POINT REACHED ***");
                console.log("Purchase #%d is no longer profitable for Bettor 1", i + 1);
            }
            
            if (!isProfitable && currentBettor == bettor2 && !bettor2BreakEven) {
                bettor2BreakEven = true;
                console.log("\n*** BETTOR 2 BREAK-EVEN POINT REACHED ***");
                console.log("Purchase #%d is no longer profitable for Bettor 2", i + 1);
            }
            
            console.log("");
            
            // Stop if both bettors have reached break-even
            if (bettor1BreakEven && bettor2BreakEven && i >= purchaseCount + 2) {
                break;
            }
        }
        
        // Summary
        console.log("\n=== Summary ===");
        console.log("Total purchases analyzed: %d", purchaseCount);
        console.log("Total wagered on entry 1: $%e", 
            PURCHASE_INCREMENT * purchaseCount);
        console.log("Final pot size: $%e", contest.getSecondarySideBalance());
        uint256 finalShares = uint256(contest.netPosition(entryId));
        console.log("Final entry 1 shares: %e", finalShares);
        if (finalShares > 0) {
            console.log("Final Bettor 1 ownership: %.2f%%", 
                _toDecimal((bettor1Shares * 1e18) / finalShares, 2));
            console.log("Final Bettor 2 ownership: %.2f%%", 
                _toDecimal((bettor2Shares * 1e18) / finalShares, 2));
        } else {
            console.log("Final ownership: 0%%");
        }
    }
    
    // Helper to get total shares across all entries
    function _getTotalShares() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= 5; i++) {
            int256 pos = contest.netPosition(i);
            if (pos > 0) {
                total += uint256(pos);
            }
        }
        return total;
    }
    
    // Helper to convert price (1e6 scale) to decimal
    function _priceToDecimal(uint256 price) internal pure returns (uint256) {
        return price / 1e4; // Returns value with 2 decimal places (e.g., 100 = 1.00)
    }
    
    // Helper to convert percentage (1e18 scale) to decimal with specified precision
    function _toDecimal(uint256 value, uint256 decimals) internal pure returns (uint256) {
        if (decimals == 2) {
            return value / 1e16; // Returns percentage with 2 decimals (e.g., 5000 = 50.00%)
        } else if (decimals == 4) {
            return value / 1e14; // Returns percentage with 4 decimals (e.g., 500000 = 50.0000%)
        }
        return value / 1e16; // Default to 2 decimals
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
