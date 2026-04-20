// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ContestController.sol";
import "../src/ContestFactory.sol";
import "solmate/tokens/ERC20.sol";

/**
 * @notice End-to-end lifecycle checks aligned with README state machine and fund-routing assumptions.
 * @dev Rounding slack: pro-rata integer division can leave wei-level dust in the contest until the last
 *      `claimSecondaryPayout` sweep; keep assertions within `ROUNDING_SLACK`.
 */
contract ContestLifecycleE2E is Test {
    uint256 public constant PRIMARY_DEPOSIT = 25e18;
    uint256 public constant PURCHASE_INCREMENT = 10e18;
    uint256 public constant ORACLE_FEE_BPS = 500;
    uint256 public constant PRIMARY_ENTRY_INVESTMENT_SHARE_BPS = 500;
    uint256 public constant ENTRY_1 = 1;
    uint256 public constant ENTRY_2 = 2;
    uint256 public constant EXPIRY_OFFSET = 365 days;
    uint256 internal constant ROUNDING_SLACK = 200 wei;

    ContestFactory internal factory;
    ContestController internal contest;
    E2EMockERC20 internal paymentToken;
    address internal oracle = address(0x1);
    address internal u1 = address(0x10);
    address internal u2 = address(0x20);
    address internal u3 = address(0x30);
    address internal u4 = address(0x40);

    function setUp() public {
        paymentToken = new E2EMockERC20("Payment Token", "PAY", 18);
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
        paymentToken.mint(u1, 1_000_000e18);
        paymentToken.mint(u2, 1_000_000e18);
        paymentToken.mint(u3, 1_000_000e18);
        paymentToken.mint(u4, 1_000_000e18);
        paymentToken.mint(oracle, 1_000_000e18);
    }

    function _fund(address u, uint256 amt, address spender) internal {
        vm.prank(u);
        paymentToken.approve(spender, amt);
    }

    function _primary(ContestController c, address u, uint256 eid) internal {
        _fund(u, PRIMARY_DEPOSIT, address(c));
        vm.prank(u);
        c.addPrimaryPosition(eid, new bytes32[](0));
    }

    function _secondary(ContestController c, address u, uint256 eid, uint256 amt) internal {
        _fund(u, amt, address(c));
        vm.prank(u);
        c.addSecondaryPosition(eid, amt, new bytes32[](0));
    }

    function _claimAllWinningSecondary(address[4] memory holders) internal {
        for (uint256 i = 0; i < holders.length; i++) {
            if (contest.balanceOf(holders[i], ENTRY_1) > 0) {
                vm.prank(holders[i]);
                contest.claimSecondaryPayout(ENTRY_1);
            }
        }
    }

    /// @dev README: SETTLED path — merged secondary TVL, primary payout, oracle fee; contest nearly empty
    function test_E2E_Settled_fullClaims_conservation() public {
        _primary(contest, u1, ENTRY_1);
        _primary(contest, u2, ENTRY_2);
        _secondary(contest, u3, ENTRY_1, PURCHASE_INCREMENT * 2);
        _secondary(contest, u4, ENTRY_2, PURCHASE_INCREMENT * 3);

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10_000;

        vm.prank(oracle);
        contest.settleContest(winners, payouts);

        assertEq(contest.getSecondarySideBalance(), PURCHASE_INCREMENT * 5);

        vm.prank(u1);
        contest.claimPrimaryPayout(ENTRY_1);

        address[4] memory holders = [u1, u2, u3, u4];
        _claimAllWinningSecondary(holders);

        assertEq(contest.totalSecondaryLiquidity(), 0);
        assertEq(contest.getSecondarySideBalance(), 0);

        vm.prank(oracle);
        contest.claimOracleFee();

        uint256 left = paymentToken.balanceOf(address(contest));
        assertLe(left, ROUNDING_SLACK);
    }

    /// @dev README oracle push — primary payouts via `pushPrimaryPayouts` match pull `claimPrimaryPayout` net to owner
    function test_E2E_Settled_primaryPushVsPull_sameNetToOwner() public {
        address pullUser = u1;
        address pushUser = u4;

        _primary(contest, pullUser, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10_000;

        vm.prank(oracle);
        contest.settleContest(winners, payouts);

        uint256 payoutGross = contest.primaryPrizePoolPayouts(ENTRY_1);
        uint256 fee = (payoutGross * ORACLE_FEE_BPS) / 10_000;
        uint256 expectedNet = payoutGross - fee;

        uint256 balBeforePull = paymentToken.balanceOf(pullUser);
        vm.prank(pullUser);
        contest.claimPrimaryPayout(ENTRY_1);
        uint256 pullNet = paymentToken.balanceOf(pullUser) - balBeforePull;
        assertEq(pullNet, expectedNet);

        address cPushAddr = factory.createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            ORACLE_FEE_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_ENTRY_INVESTMENT_SHARE_BPS
        );
        ContestController cPush = ContestController(cPushAddr);
        _primary(cPush, pushUser, ENTRY_1);

        vm.prank(oracle);
        cPush.activateContest();
        vm.prank(oracle);
        cPush.lockContest();
        vm.prank(oracle);
        cPush.settleContest(winners, payouts);

        uint256 balBeforePush = paymentToken.balanceOf(pushUser);
        uint256[] memory entryIds = new uint256[](1);
        entryIds[0] = ENTRY_1;
        vm.prank(oracle);
        cPush.pushPrimaryPayouts(entryIds);
        uint256 pushNet = paymentToken.balanceOf(pushUser) - balBeforePush;
        assertEq(pushNet, expectedNet);
    }

    /// @dev README CANCELLED — full refunds, no oracle fee on removes
    function test_E2E_Cancelled_refundsNoOracleFee() public {
        uint256 u1Pre = paymentToken.balanceOf(u1);
        uint256 u3Pre = paymentToken.balanceOf(u3);

        _primary(contest, u1, ENTRY_1);
        _secondary(contest, u3, ENTRY_1, PURCHASE_INCREMENT * 2);

        vm.prank(oracle);
        contest.cancelContest();

        uint256 bal = contest.balanceOf(u3, ENTRY_1);
        vm.prank(u3);
        contest.removeSecondaryPosition(ENTRY_1, bal);

        vm.prank(u1);
        contest.removePrimaryPosition(ENTRY_1);

        assertEq(paymentToken.balanceOf(u1), u1Pre);
        // Bonding-curve sell-back can be a few wei short of exact deposits at this size
        assertApproxEqAbs(paymentToken.balanceOf(u3), u3Pre, 2e18);
        assertEq(contest.accumulatedOracleFee(), 0);
    }

    /// @dev README `cancelExpired` — anyone may move to CANCELLED after expiry when not settled/closed
    function test_E2E_CancelExpired_thenRefunds() public {
        uint256 u1Pre = paymentToken.balanceOf(u1);
        uint256 u3Pre = paymentToken.balanceOf(u3);

        _primary(contest, u1, ENTRY_1);
        _secondary(contest, u3, ENTRY_1, PURCHASE_INCREMENT);

        vm.warp(block.timestamp + EXPIRY_OFFSET + 1);
        contest.cancelExpired();
        assertEq(uint8(contest.state()), uint8(4));

        uint256 bal = contest.balanceOf(u3, ENTRY_1);
        vm.prank(u3);
        contest.removeSecondaryPosition(ENTRY_1, bal);

        vm.prank(u1);
        contest.removePrimaryPosition(ENTRY_1);

        assertEq(paymentToken.balanceOf(u1), u1Pre);
        assertApproxEqAbs(paymentToken.balanceOf(u3), u3Pre, 2e18);
    }

    /// @dev README CLOSED — residual ERC20 sent to oracle; accounting zeroed
    function test_E2E_CloseContest_routesResidualToOracle() public {
        _primary(contest, u1, ENTRY_1);
        uint256 oracleBefore = paymentToken.balanceOf(oracle);

        vm.warp(block.timestamp + EXPIRY_OFFSET + 1);
        vm.prank(oracle);
        contest.closeContest();

        assertEq(uint8(contest.state()), uint8(5));
        assertGt(paymentToken.balanceOf(oracle), oracleBefore);
        assertEq(contest.getSecondarySideBalance(), 0);
        assertEq(contest.getPrimarySideBalance(), 0);
    }

    /// @dev Merged secondary with no winning-entry supply spills to primary; primary owner realizes it
    function test_E2E_Settled_noWinningSecondarySupply_spillToPrimary() public {
        _primary(contest, u1, ENTRY_1);
        _primary(contest, u2, ENTRY_2);
        _secondary(contest, u3, ENTRY_2, PURCHASE_INCREMENT);

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10_000;

        uint256 primaryPool = contest.primaryPrizePool();
        vm.prank(oracle);
        contest.settleContest(winners, payouts);

        assertEq(contest.getSecondarySideBalance(), 0);
        assertEq(contest.primaryPrizePoolPayouts(ENTRY_1), primaryPool + PURCHASE_INCREMENT);

        uint256 before = paymentToken.balanceOf(u1);
        vm.prank(u1);
        contest.claimPrimaryPayout(ENTRY_1);
        assertGt(paymentToken.balanceOf(u1), before);
    }
}

contract E2EMockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
