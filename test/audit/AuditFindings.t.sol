// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/ContestController.sol";
import "../../src/ContestFactory.sol";
import "../helpers/ReferralTestHarness.sol";
import "solmate/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK", 18) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockUSDTLikeToken is ERC20 {
    constructor() ERC20("MockUSDT", "MUSDT", 6) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

contract AuditFindingsTest is ReferralTestHarness {
    MockERC20 internal token;
    address internal operator;
    address internal alice;
    address internal bob;

    uint256 internal constant PRIMARY_DEPOSIT = 100e18;
    uint256 internal constant EXPIRY_OFFSET = 7 days;
    uint256 internal constant SUBSIDY_BPS = 700;

    function setUp() public {
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        
        token = new MockERC20();
        _initReferralInfra(address(token), operator);
        
        token.mint(alice, 10000e18);
        token.mint(bob, 10000e18);
    }

    function test_Finding_RoundingDustInPayouts() public {
        ContestController contest = _createContest(
            PRIMARY_DEPOSIT,
            REFERRAL_NETWORK_BPS,
            block.timestamp + EXPIRY_OFFSET,
            SUBSIDY_BPS
        );

        vm.startPrank(alice);
        token.approve(address(contest), PRIMARY_DEPOSIT * 3);
        contest.addPrimaryPosition(1, new bytes32[](0));
        contest.addPrimaryPosition(2, new bytes32[](0));
        contest.addPrimaryPosition(3, new bytes32[](0));
        vm.stopPrank();

        vm.prank(operator);
        contest.activateContest();

        vm.prank(operator);
        contest.lockContest();

        uint256[] memory winners = new uint256[](3);
        winners[0] = 1;
        winners[1] = 2;
        winners[2] = 3;
        
        uint256[] memory payoutBps = new uint256[](3);
        payoutBps[0] = 3333;
        payoutBps[1] = 3333;
        payoutBps[2] = 3334;
        
        _settleContest(contest, winners, payoutBps);

        uint256 totalPayouts = 0;
        for (uint256 i = 0; i < winners.length; i++) {
            totalPayouts += contest.primaryPrizePoolPayouts(winners[i]);
        }
        
        uint256 primaryPool = contest.getPrimarySideBalance();
        
        console.log("Total Payouts allocated:", totalPayouts);
        console.log("Primary pool remaining:", primaryPool);
        
        if (primaryPool > totalPayouts) {
            console.log("Dust remaining:", primaryPool - totalPayouts);
        }
    }

    function test_Finding_NoSlippageProtection() public {
        ContestController contest = _createContest(
            PRIMARY_DEPOSIT,
            0,
            block.timestamp + EXPIRY_OFFSET,
            SUBSIDY_BPS
        );

        vm.prank(alice);
        token.approve(address(contest), PRIMARY_DEPOSIT);
        vm.prank(alice);
        contest.addPrimaryPosition(1, new bytes32[](0));

        vm.prank(operator);
        contest.activateContest();

        vm.prank(bob);
        token.approve(address(contest), 1000e18);
        
        uint256 buyAmount = 10e18;
        
        uint256 price1 = contest.calculateSecondaryPrice(1);
        console.log("Price before Bob's buy:", price1);
        
        vm.prank(bob);
        contest.addSecondaryPosition(1, buyAmount, new bytes32[](0));
        
        uint256 price2 = contest.calculateSecondaryPrice(1);
        console.log("Price after Bob's first buy:", price2);
        
        vm.prank(bob);
        contest.addSecondaryPosition(1, buyAmount, new bytes32[](0));
        
        uint256 price3 = contest.calculateSecondaryPrice(1);
        console.log("Price after Bob's second buy:", price3);
        
        assertTrue(price2 > price1, "Price should increase after buy");
        assertTrue(price3 > price2, "Price should increase after second buy");
    }

    function test_Finding_OnChainWinnerCheck() public {
        ContestController contest = _createContest(
            PRIMARY_DEPOSIT,
            0,
            block.timestamp + EXPIRY_OFFSET,
            SUBSIDY_BPS
        );

        vm.prank(alice);
        token.approve(address(contest), PRIMARY_DEPOSIT * 2);
        vm.prank(alice);
        contest.addPrimaryPosition(1, new bytes32[](0));
        vm.prank(alice);
        contest.addPrimaryPosition(2, new bytes32[](0));

        vm.prank(operator);
        contest.activateContest();

        vm.prank(operator);
        contest.lockContest();

        uint256[] memory winners = new uint256[](2);
        winners[0] = 1;
        winners[1] = 2;
        
        uint256[] memory payoutBps = new uint256[](2);
        payoutBps[0] = 10000;
        payoutBps[1] = 0;
        
        vm.prank(operator);
        vm.expectRevert("Use non-zero payouts only");
        contest.settleContest(winners, payoutBps, 1, bytes32(0), 0, address(0), "");
    }
}
