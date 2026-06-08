// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/ContestController.sol";
import "../../src/ContestFactory.sol";
import "referralTree/core/ReferralGraph.sol";
import "referralTree/core/RewardDistributor.sol";
import "referralTree/interfaces/IRewardDistributor.sol";
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
    RewardDistributor internal rewardDistributor;
    ContestFactory internal factory;

    address internal referralOwner;
    address internal referralOracleSigner;

    function _initReferralInfra() internal {
        referralOwner = address(this);
        referralOracleSigner = vm.addr(referralOracleKey);

        referralGraph = new ReferralGraph(referralOwner, referralOracleSigner, REFERRAL_GROUP_ID);
        rewardDistributor =
            new RewardDistributor(referralOwner, address(referralGraph), referralOracleSigner, REFERRAL_GROUP_ID);
        factory = new ContestFactory();
    }

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
            address(rewardDistributor),
            REFERRAL_GROUP_ID
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

    function _referralRewardHash(IRewardDistributor.ChainRewardData memory reward)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(reward.user, reward.totalAmount, reward.rewardToken, reward.groupId, reward.eventId)
        );
    }

    function _signReferralReward(IRewardDistributor.ChainRewardData memory reward)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 rewardHash = _referralRewardHash(reward);
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", rewardHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(referralOracleKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _buildReferralReward(
        ContestController c,
        address payoutAnchor,
        uint256 referralFee,
        bytes32 eventId
    ) internal view returns (IRewardDistributor.ChainRewardData memory reward) {
        reward = IRewardDistributor.ChainRewardData({
            user: payoutAnchor,
            totalAmount: referralFee,
            rewardToken: c.paymentToken(),
            groupId: REFERRAL_GROUP_ID,
            eventId: eventId
        });
    }

    function _settleContest(ContestController c, uint256[] memory winningEntries, uint256[] memory payoutBps)
        internal
    {
        uint256 referralFee = _referralFeeAmount(c);
        IRewardDistributor.ChainRewardData memory reward;
        bytes memory signature;

        if (referralFee > 0) {
            address winner = c.entryOwner(winningEntries[0]);
            address payoutAnchor = referralGraph.getReferrer(winner, REFERRAL_GROUP_ID);

            if (payoutAnchor != address(0) && payoutAnchor != REFERRAL_ROOT) {
                bytes32 eventId = keccak256(abi.encodePacked(address(c), block.timestamp, winningEntries[0]));
                reward = _buildReferralReward(c, payoutAnchor, referralFee, eventId);
                signature = _signReferralReward(reward);
            }
        }

        vm.prank(c.oracle());
        c.settleContest(winningEntries, payoutBps, reward, signature);
    }

    function _settleContestExpectRevert(
        ContestController c,
        uint256[] memory winningEntries,
        uint256[] memory payoutBps,
        bytes memory reason
    ) internal {
        IRewardDistributor.ChainRewardData memory reward;
        bytes memory signature;
        vm.prank(c.oracle());
        vm.expectRevert(reason);
        c.settleContest(winningEntries, payoutBps, reward, signature);
    }

    function _netBps(ContestController c) internal view returns (uint256) {
        return 10_000 - c.referralNetworkBps();
    }
}
