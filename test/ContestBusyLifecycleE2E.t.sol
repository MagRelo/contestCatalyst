// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ContestController.sol";
import "../src/ContestFactory.sol";
import "solmate/tokens/ERC20.sol";

contract ContestBusyLifecycleE2E is Test {
    uint256 public constant PRIMARY_DEPOSIT = 25e18;
    uint256 public constant PURCHASE_INCREMENT = 10e18;
    uint256 public constant ORACLE_FEE_BPS = 500;
    uint256 public constant PRIMARY_ENTRY_INVESTMENT_SHARE_BPS = 500;
    uint256 public constant ENTRY_1 = 1;
    uint256 public constant ENTRY_2 = 2;
    uint256 public constant ENTRY_3 = 3;
    uint256 public constant EXPIRY_OFFSET = 365 days;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    ContestFactory internal factory;
    ContestController internal contest;
    BusyE2EMockERC20 internal paymentToken;

    address internal oracle = address(0x1);
    address internal p1 = address(0x10);
    address internal p2 = address(0x20);
    address internal p3 = address(0x30);
    address internal b1 = address(0x40);
    address internal b2 = address(0x50);
    address internal b3 = address(0x60);
    address internal b4 = address(0x70);
    address internal b5 = address(0x80);

    function setUp() public {
        paymentToken = new BusyE2EMockERC20("Payment Token", "PAY", 18);
        factory = new ContestFactory();
        address c = factory.createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            ORACLE_FEE_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_ENTRY_INVESTMENT_SHARE_BPS
        );
        contest = ContestController(c);

        paymentToken.mint(oracle, 1_000_000e18);
        paymentToken.mint(p1, 1_000_000e18);
        paymentToken.mint(p2, 1_000_000e18);
        paymentToken.mint(p3, 1_000_000e18);
        paymentToken.mint(b1, 1_000_000e18);
        paymentToken.mint(b2, 1_000_000e18);
        paymentToken.mint(b3, 1_000_000e18);
        paymentToken.mint(b4, 1_000_000e18);
        paymentToken.mint(b5, 1_000_000e18);
    }

    function _approve(address user, uint256 amount) internal {
        vm.prank(user);
        paymentToken.approve(address(contest), amount);
    }

    function _primary(address user, uint256 entryId) internal {
        _approve(user, PRIMARY_DEPOSIT);
        vm.prank(user);
        contest.addPrimaryPosition(entryId, new bytes32[](0));
    }

    function _secondary(address user, uint256 entryId, uint256 amount) internal {
        _approve(user, amount);
        vm.prank(user);
        contest.addSecondaryPosition(entryId, amount, new bytes32[](0));
    }

    function _claimPrimaryAndAssert(address winner, uint256 entryId) internal returns (uint256 oracleFee) {
        uint256 gross = contest.primaryPrizePoolPayouts(entryId);
        oracleFee = (gross * ORACLE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 expectedNet = gross - oracleFee;

        uint256 before = paymentToken.balanceOf(winner);
        vm.prank(winner);
        contest.claimPrimaryPayout(entryId);
        uint256 afterBal = paymentToken.balanceOf(winner);

        assertEq(afterBal - before, expectedNet);
        assertEq(contest.primaryPrizePoolPayouts(entryId), 0);
    }

    function _claimSecondaryAndAssert(address holder, uint256 entryId) internal returns (uint256 oracleFee) {
        uint256 holderTokens = contest.balanceOf(holder, entryId);
        if (holderTokens == 0) {
            return 0;
        }

        uint256 liquidityBefore = contest.secondaryLiquidityPerEntry(entryId);
        uint256 supplyBefore = uint256(contest.netPosition(entryId));
        uint256 gross = (holderTokens * liquidityBefore) / supplyBefore;
        oracleFee = (gross * ORACLE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 expectedNet = gross - oracleFee;

        uint256 contractBalBefore = paymentToken.balanceOf(address(contest));
        uint256 feesBefore = contest.accumulatedOracleFee();
        uint256 expectedReceived = expectedNet;

        // Last claimant receives any remaining non-fee dust via the internal sweep.
        if (holderTokens == supplyBefore) {
            uint256 remainingAfterNetTransfer = contractBalBefore - expectedNet;
            uint256 feesAfter = feesBefore + oracleFee;
            uint256 expectedSweep = remainingAfterNetTransfer > feesAfter ? remainingAfterNetTransfer - feesAfter : 0;
            expectedReceived += expectedSweep;
        }

        uint256 before = paymentToken.balanceOf(holder);
        vm.prank(holder);
        contest.claimSecondaryPayout(entryId);
        uint256 afterBal = paymentToken.balanceOf(holder);

        assertEq(afterBal - before, expectedReceived);
        assertEq(contest.balanceOf(holder, entryId), 0);
    }

    function test_E2E_HappyPath_BusyContest_fullDistributionAndZeroed() public {
        // Multiple primary participants enter.
        _primary(p1, ENTRY_1);
        _primary(p2, ENTRY_2);
        _primary(p3, ENTRY_3);

        // Busy secondary market across multiple entries.
        _secondary(b1, ENTRY_1, PURCHASE_INCREMENT * 3);
        _secondary(b2, ENTRY_2, PURCHASE_INCREMENT * 5);
        _secondary(b3, ENTRY_2, PURCHASE_INCREMENT * 2);
        _secondary(b4, ENTRY_3, PURCHASE_INCREMENT * 4);
        _secondary(b5, ENTRY_1, PURCHASE_INCREMENT * 1);
        _secondary(p1, ENTRY_2, PURCHASE_INCREMENT * 2);

        uint256 totalSecondaryBought =
            (PURCHASE_INCREMENT * 3) + (PURCHASE_INCREMENT * 5) + (PURCHASE_INCREMENT * 2) + (PURCHASE_INCREMENT * 4)
                + (PURCHASE_INCREMENT * 1) + (PURCHASE_INCREMENT * 2);
        assertEq(contest.getSecondarySideBalance(), totalSecondaryBought);

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        // Two primary winners; secondary winner is first winner (ENTRY_2).
        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_2;
        winners[1] = ENTRY_1;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 7_000;
        payouts[1] = 3_000;

        vm.prank(oracle);
        contest.settleContest(winners, payouts);

        // All secondary liquidity is merged onto the winning secondary entry.
        assertEq(contest.secondaryLiquidityPerEntry(ENTRY_2), totalSecondaryBought);
        assertEq(contest.secondaryLiquidityPerEntry(ENTRY_1), 0);
        assertEq(contest.secondaryLiquidityPerEntry(ENTRY_3), 0);
        assertEq(contest.getSecondarySideBalance(), totalSecondaryBought);

        uint256 expectedOracleFees;

        // Primary winners are paid net, oracle fees accrue.
        expectedOracleFees += _claimPrimaryAndAssert(p2, ENTRY_2);
        expectedOracleFees += _claimPrimaryAndAssert(p1, ENTRY_1);

        // Winning secondary holders redeem pro-rata against merged liquidity.
        // Holders include owner-leg recipient p2 and buyers on ENTRY_2.
        expectedOracleFees += _claimSecondaryAndAssert(p2, ENTRY_2);
        expectedOracleFees += _claimSecondaryAndAssert(b2, ENTRY_2);
        expectedOracleFees += _claimSecondaryAndAssert(b3, ENTRY_2);
        expectedOracleFees += _claimSecondaryAndAssert(p1, ENTRY_2);

        assertEq(contest.totalSecondaryLiquidity(), 0);
        assertEq(contest.getSecondarySideBalance(), 0);
        assertEq(uint256(contest.netPosition(ENTRY_2)), 0);
        assertEq(paymentToken.balanceOf(address(contest)), contest.accumulatedOracleFee());
        assertEq(contest.accumulatedOracleFee(), expectedOracleFees);

        uint256 oracleBefore = paymentToken.balanceOf(oracle);
        vm.prank(oracle);
        contest.claimOracleFee();
        uint256 oracleAfter = paymentToken.balanceOf(oracle);

        assertEq(oracleAfter - oracleBefore, expectedOracleFees);
        assertEq(contest.accumulatedOracleFee(), 0);
        assertEq(paymentToken.balanceOf(address(contest)), 0);
    }
}

contract BusyE2EMockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
