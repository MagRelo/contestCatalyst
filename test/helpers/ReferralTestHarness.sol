// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/ContestController.sol";
import "../../src/ContestFactory.sol";
import "referralTree/core/ReferralGraph.sol";
import "referralTree/core/RewardCalculator.sol";
import "referralTree/interfaces/IReferralGraph.sol";

/**
 * @dev Shared referral infrastructure for contest tests.
 */
abstract contract ReferralTestHarness is Test {
    uint256 internal constant REFERRAL_NETWORK_BPS = 500;
    bytes32 internal constant REFERRAL_GROUP_ID = keccak256("contest-catalyst-v1");
    address internal constant REFERRAL_ROOT = address(0x0000000000000000000000000000000000000001);

    uint256 internal referralOracleKey = 0xA11CE;

    ReferralGraph internal referralGraph;
    RewardCalculator internal rewardCalculator;
    ContestFactory internal factory;

    address internal referralOwner;
    address internal referralOracleSigner;

    function _initReferralInfra() internal {
        referralOwner = address(this);
        referralOracleSigner = vm.addr(referralOracleKey);

        referralGraph = new ReferralGraph(referralOwner, referralOracleSigner, REFERRAL_GROUP_ID);
        rewardCalculator = new RewardCalculator();
        factory = new ContestFactory();
    }

    address internal constant EMERGENCY_RECOVERY = address(0xE1);

    function _createContest(
        address paymentToken,
        address contestOracle,
        uint256 primaryDeposit,
        uint256 referralBps,
        uint256 expiry,
        uint256 subsidyBps
    ) internal returns (ContestController) {
        address addr = factory.createContest(
            paymentToken,
            contestOracle,
            primaryDeposit,
            referralBps,
            expiry,
            subsidyBps,
            address(referralGraph),
            address(rewardCalculator),
            REFERRAL_GROUP_ID,
            EMERGENCY_RECOVERY
        );
        return ContestController(addr);
    }

    function _registerWinnerReferrer(address winner, address payoutAnchor) internal {
        vm.prank(referralOracleSigner);
        referralGraph.register(payoutAnchor, REFERRAL_ROOT, REFERRAL_GROUP_ID);
        vm.prank(referralOracleSigner);
        referralGraph.register(winner, payoutAnchor, REFERRAL_GROUP_ID);
    }

    function _computeGrossTvl(ContestController c) internal view returns (uint256 totalPrimary, uint256 totalSecondary) {
        totalPrimary = c.getPrimarySideBalance();
        totalSecondary = c.getSecondarySideBalance();
    }

    function _referralFeeAmount(ContestController c) internal view returns (uint256) {
        (uint256 totalPrimary, uint256 totalSecondary) = _computeGrossTvl(c);
        uint256 totalGross = totalPrimary + totalSecondary;
        if (c.referralNetworkBps() == 0 || totalGross == 0) return 0;
        return (totalGross * c.referralNetworkBps()) / 10_000;
    }

    /// @dev Primary/secondary shares when an undistributed referral fee is restored (S-3).
    function _referralFeeRestoreShares(uint256 fee, uint256 totalPrimary, uint256 totalSecondary)
        internal
        pure
        returns (uint256 toPrimary, uint256 toSecondary)
    {
        uint256 totalGross = totalPrimary + totalSecondary;
        if (fee == 0 || totalGross == 0) return (fee, 0);
        toSecondary = (fee * totalSecondary) / totalGross;
        toPrimary = fee - toSecondary;
    }

    /// @dev Expected secondary pool after settle when the referral fee is fully restored (no payable referrer).
    function _expectedNetSecondaryAfterFeeRestore(
        uint256 totalPrimary,
        uint256 grossSecondary,
        uint256 referralBps
    ) internal pure returns (uint256) {
        uint256 totalGross = totalPrimary + grossSecondary;
        uint256 fee = (referralBps == 0 || totalGross == 0) ? 0 : (totalGross * referralBps) / 10_000;
        (, uint256 backToSecondary) = _referralFeeRestoreShares(fee, totalPrimary, grossSecondary);
        return (grossSecondary * (10_000 - referralBps)) / 10_000 + backToSecondary;
    }

    function _settleContest(ContestController c, uint256[] memory winningEntries, uint256[] memory payoutBps)
        internal
    {
        if (c.state() == ContestController.ContestState.ACTIVE) {
            vm.prank(c.oracle());
            c.lockContest();
        }
        vm.prank(c.oracle());
        c.settleContest(winningEntries, payoutBps);
    }

    function _settleContestExpectRevert(
        ContestController c,
        uint256[] memory winningEntries,
        uint256[] memory payoutBps,
        bytes memory reason
    ) internal {
        if (c.state() == ContestController.ContestState.ACTIVE) {
            vm.prank(c.oracle());
            c.lockContest();
        }
        vm.prank(c.oracle());
        vm.expectRevert(reason);
        c.settleContest(winningEntries, payoutBps);
    }

    /// @dev Activate if still OPEN so secondary buys succeed under ACTIVE-only gating.
    function _ensureActiveForSecondary(ContestController c) internal {
        if (c.state() == ContestController.ContestState.OPEN) {
            vm.prank(c.oracle());
            c.activateContest();
        }
    }

    function _netBps(ContestController c) internal view returns (uint256) {
        return 10_000 - c.referralNetworkBps();
    }
}
