// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/ContestController.sol";
import "./helpers/ReferralTestHarness.sol";
import "solmate/tokens/ERC20.sol";

contract ContestBusyLifecycleE2E is ReferralTestHarness {
    uint256 public constant PRIMARY_DEPOSIT = 25e18;
    uint256 public constant PURCHASE_INCREMENT = 10e18;
    uint256 public constant PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS = 700;
    uint256 public constant ENTRY_1 = 1;
    uint256 public constant ENTRY_2 = 2;
    uint256 public constant ENTRY_3 = 3;
    uint256 public constant EXPIRY_OFFSET = 365 days;
    uint256 internal constant ROUNDING_SLACK = 500 wei;

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
        _initReferralInfra();
        contest = _createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            REFERRAL_NETWORK_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS
        );

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
        _ensureActiveForSecondary(contest);
        _approve(user, amount);
        vm.prank(user);
        contest.addSecondaryPosition(entryId, amount, new bytes32[](0));
    }

    function _claimPrimaryAndAssert(address winner, uint256 entryId) internal {
        uint256 payout = contest.primaryPrizePoolPayouts(entryId);
        uint256 before = paymentToken.balanceOf(winner);
        vm.prank(winner);
        contest.claimPrimaryPayout(entryId);
        assertEq(paymentToken.balanceOf(winner) - before, payout);
        assertEq(contest.primaryPrizePoolPayouts(entryId), 0);
    }

    function _claimSecondaryAndAssert(address holder, uint256 entryId) internal {
        uint256 holderTokens = contest.balanceOf(holder, entryId);
        if (holderTokens == 0) {
            return;
        }

        uint256 liquidityBefore = contest.secondaryLiquidityPerEntry(entryId);
        uint256 supplyBefore = uint256(contest.netPosition(entryId));
        uint256 expected = (holderTokens * liquidityBefore) / supplyBefore;

        uint256 contractBalBefore = paymentToken.balanceOf(address(contest));
        uint256 expectedReceived = expected;

        if (holderTokens == supplyBefore) {
            uint256 remainingAfterTransfer = contractBalBefore - expected;
            expectedReceived += remainingAfterTransfer;
        }

        uint256 before = paymentToken.balanceOf(holder);
        vm.prank(holder);
        contest.claimSecondaryPayout(entryId);
        assertEq(paymentToken.balanceOf(holder) - before, expectedReceived);
        assertEq(contest.balanceOf(holder, entryId), 0);
    }

    function test_E2E_HappyPath_BusyContest_fullDistributionAndZeroed() public {
        _primary(p1, ENTRY_1);
        _primary(p2, ENTRY_2);
        _primary(p3, ENTRY_3);

        _secondary(b1, ENTRY_1, PURCHASE_INCREMENT * 3);
        _secondary(b2, ENTRY_2, PURCHASE_INCREMENT * 5);
        _secondary(b3, ENTRY_2, PURCHASE_INCREMENT * 2);
        _secondary(b4, ENTRY_3, PURCHASE_INCREMENT * 4);
        _secondary(b5, ENTRY_1, PURCHASE_INCREMENT * 1);
        _secondary(p1, ENTRY_2, PURCHASE_INCREMENT * 2);

        uint256 totalSecondaryBought =
            (PURCHASE_INCREMENT * 3) + (PURCHASE_INCREMENT * 5) + (PURCHASE_INCREMENT * 2) + (PURCHASE_INCREMENT * 4)
                + (PURCHASE_INCREMENT * 1) + (PURCHASE_INCREMENT * 2);
        uint256 threeSubsidy = 3 * ((PRIMARY_DEPOSIT * PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS) / 10_000);
        assertEq(contest.getSecondarySideBalance(), totalSecondaryBought + threeSubsidy);

        vm.prank(oracle);
        contest.lockContest();

        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_2;
        winners[1] = ENTRY_1;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 7_000;
        payouts[1] = 3_000;

        uint256 expectedReferralFee = _referralFeeAmount(contest);
        uint256 oracleBefore = paymentToken.balanceOf(oracle);
        _settleContest(contest, winners, payouts);
        assertEq(paymentToken.balanceOf(oracle) - oracleBefore, expectedReferralFee);

        uint256 grossSecondary = totalSecondaryBought + threeSubsidy;
        uint256 netSecondary = (grossSecondary * _netBps(contest)) / 10_000;
        assertEq(contest.secondaryLiquidityPerEntry(ENTRY_2), netSecondary);
        assertEq(contest.secondaryLiquidityPerEntry(ENTRY_1), 0);
        assertEq(contest.secondaryLiquidityPerEntry(ENTRY_3), 0);
        assertEq(contest.getSecondarySideBalance(), netSecondary);

        _claimPrimaryAndAssert(p2, ENTRY_2);
        _claimPrimaryAndAssert(p1, ENTRY_1);

        _claimSecondaryAndAssert(p2, ENTRY_2);
        _claimSecondaryAndAssert(b2, ENTRY_2);
        _claimSecondaryAndAssert(b3, ENTRY_2);
        _claimSecondaryAndAssert(p1, ENTRY_2);

        assertEq(contest.totalSecondaryLiquidity(), 0);
        assertEq(contest.getSecondarySideBalance(), 0);
        assertEq(uint256(contest.netPosition(ENTRY_2)), 0);

        uint256 left = paymentToken.balanceOf(address(contest));
        assertLe(left, ROUNDING_SLACK);
    }
}

contract BusyE2EMockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
