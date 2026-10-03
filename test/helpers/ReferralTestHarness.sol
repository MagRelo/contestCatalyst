// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
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
    address internal harnessPaymentToken;
    address internal harnessOperator;

    function _initReferralInfra(address paymentToken, address contestOperator) internal {
        referralOwner = address(this);
        referralOracleSigner = vm.addr(referralOracleKey);
        harnessPaymentToken = paymentToken;
        harnessOperator = contestOperator;

        referralGraph = new ReferralGraph(referralOwner, referralOracleSigner, REFERRAL_GROUP_ID);
        rewardCalculator = new RewardCalculator();
        referralGraph.setRewardCalculator(address(rewardCalculator));
        factory = new ContestFactory(
            paymentToken,
            contestOperator,
            address(referralGraph),
            address(rewardCalculator),
            REFERRAL_GROUP_ID
        );
    }

    function _createContest(
        uint256 primaryDeposit,
        uint256 referralBps,
        uint256 expiry,
        uint256 subsidyBps
    ) internal returns (ContestController) {
        address addr = factory.createContest(primaryDeposit, referralBps, expiry, subsidyBps);
        return ContestController(addr);
    }

    /// @dev One-off factory with a different payment token (same operator / referral infra).
    function _createContestWithToken(
        address paymentToken,
        uint256 primaryDeposit,
        uint256 referralBps,
        uint256 expiry,
        uint256 subsidyBps
    ) internal returns (ContestController) {
        ContestFactory customFactory = new ContestFactory(
            paymentToken,
            harnessOperator,
            address(referralGraph),
            address(rewardCalculator),
            REFERRAL_GROUP_ID
        );
        address addr = customFactory.createContest(primaryDeposit, referralBps, expiry, subsidyBps);
        return ContestController(addr);
    }

    /// @dev One-off factory wired to a non-canonical calculator (fallback tests).
    function _createContestWithCalculator(
        uint256 primaryDeposit,
        uint256 referralBps,
        uint256 expiry,
        uint256 subsidyBps,
        address calculator
    ) internal returns (ContestController) {
        ContestFactory customFactory = new ContestFactory(
            harnessPaymentToken,
            harnessOperator,
            address(referralGraph),
            calculator,
            REFERRAL_GROUP_ID
        );
        address addr = customFactory.createContest(primaryDeposit, referralBps, expiry, subsidyBps);
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
    /// @param totalPrimary Post-loan-repay primary TVL
    /// @param totalSecondary Post-loan-repay secondary TVL
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

    /// @dev Apply settle-time subsidy loan repay: BPS of secondary TVL credited back to primary.
    function _applySubsidyLoanRepay(uint256 totalPrimary, uint256 grossSecondary, uint256 subsidyBps)
        internal
        pure
        returns (uint256 rebalPrimary, uint256 rebalSecondary)
    {
        uint256 repay = (grossSecondary * subsidyBps) / 10_000;
        rebalPrimary = totalPrimary + repay;
        rebalSecondary = grossSecondary - repay;
    }

    /// @dev Expected secondary pool after settle when the referral fee is fully restored (no payable referrer).
    function _expectedNetSecondaryAfterFeeRestore(
        uint256 totalPrimary,
        uint256 grossSecondary,
        uint256 referralBps,
        uint256 subsidyBps
    ) internal pure returns (uint256) {
        (uint256 rebalPrimary, uint256 rebalSecondary) =
            _applySubsidyLoanRepay(totalPrimary, grossSecondary, subsidyBps);
        uint256 totalGross = totalPrimary + grossSecondary;
        uint256 fee = (referralBps == 0 || totalGross == 0) ? 0 : (totalGross * referralBps) / 10_000;
        (, uint256 backToSecondary) = _referralFeeRestoreShares(fee, rebalPrimary, rebalSecondary);
        return (rebalSecondary * (10_000 - referralBps)) / 10_000 + backToSecondary;
    }

    function _settleContest(ContestController c, uint256[] memory winningEntries, uint256[] memory payoutBps)
        internal
    {
        uint256 secondaryWinner = winningEntries.length > 0 ? winningEntries[0] : 0;
        _settleContest(c, winningEntries, payoutBps, secondaryWinner);
    }

    function _settleContest(
        ContestController c,
        uint256[] memory winningEntries,
        uint256[] memory payoutBps,
        uint256 secondaryWinner
    ) internal {
        _settleContest(c, winningEntries, payoutBps, secondaryWinner, bytes32(0));
    }

    function _settleContest(
        ContestController c,
        uint256[] memory winningEntries,
        uint256[] memory payoutBps,
        uint256 secondaryWinner,
        bytes32 referralNonce
    ) internal {
        if (c.state() == ContestController.ContestState.ACTIVE) {
            vm.prank(c.operator());
            c.lockContest();
        }
        (uint256 deadline, address oracle, bytes memory signature) =
            _referralAuth(c, _primaryWinnerEntry(winningEntries, payoutBps), referralNonce);
        vm.prank(c.operator());
        c.settleContest(winningEntries, payoutBps, secondaryWinner, referralNonce, deadline, oracle, signature);
    }

    /// @dev Entry with the largest primary share. Ties keep the earlier `winningEntries` element.
    function _primaryWinnerEntry(uint256[] memory winningEntries, uint256[] memory payoutBps)
        internal
        pure
        returns (uint256 entryId)
    {
        uint256 bestBps;
        uint256 n = winningEntries.length < payoutBps.length ? winningEntries.length : payoutBps.length;
        for (uint256 i = 0; i < n; i++) {
            if (payoutBps[i] > bestBps) {
                bestBps = payoutBps[i];
                entryId = winningEntries[i];
            }
        }
    }

    /// @dev Signs RewardRoots when this settle has a payable referrer chain. Otherwise the signature is unused.
    function _referralAuth(ContestController c, uint256 primaryWinnerEntry, bytes32 referralNonce)
        internal
        view
        returns (uint256 deadline, address oracle, bytes memory signature)
    {
        deadline = block.timestamp + 1 days;
        oracle = referralOracleSigner;
        address winner = c.entryOwner(primaryWinnerEntry);
        if (winner == address(0) || c.referralNetworkBps() == 0) return (deadline, oracle, signature);

        address[] memory chain =
            referralGraph.getPayoutAncestors(winner, c.referralGroupId(), c.MAX_REFERRAL_PAYOUT_LEVELS());
        if (chain.length == 0) return (deadline, oracle, signature);

        uint256 fee = _referralFeeAmount(c);
        if (fee == 0) return (deadline, oracle, signature);

        signature = _signRewardRoots(c, address(c), winner, fee, deadline, referralNonce);
    }

    function _assertRootsRewarded(
        ContestController c,
        address triggerUser,
        uint256 distributedAmount,
        bytes32 referralNonce
    ) internal view {
        _assertRootsRewarded(vm.getRecordedLogs(), c, triggerUser, distributedAmount, referralNonce);
    }

    function _assertRootsRewarded(
        Vm.Log[] memory logs,
        ContestController c,
        address triggerUser,
        uint256 distributedAmount,
        bytes32 referralNonce
    ) internal view {
        bytes32 topic = keccak256("RootsRewarded(bytes32,bytes32,address,address,uint256,address[],uint256[])");
        bytes32 rewardId = c.referralRewardId(referralNonce);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(referralGraph) || logs[i].topics[0] != topic) continue;
            assertEq(logs[i].topics[1], c.referralGroupId());
            assertEq(logs[i].topics[2], rewardId);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), triggerUser);
            (address token, uint256 amount,,) = abi.decode(logs[i].data, (address, uint256, address[], uint256[]));
            assertEq(token, c.paymentToken());
            assertEq(amount, distributedAmount);
            return;
        }
        revert("RootsRewarded not emitted");
    }

    function _assertProtocolFeeCharged(
        Vm.Log[] memory logs,
        ContestController c,
        address recipient,
        uint256 amount,
        bytes32 referralNonce
    ) internal view {
        bytes32 topic = keccak256("ProtocolFeeCharged(bytes32,bytes32,address,address,uint256)");
        bytes32 rewardId = c.referralRewardId(referralNonce);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(referralGraph) || logs[i].topics[0] != topic) continue;
            assertEq(logs[i].topics[1], c.referralGroupId());
            assertEq(logs[i].topics[2], rewardId);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), c.paymentToken());
            (address gotRecipient, uint256 gotAmount) = abi.decode(logs[i].data, (address, uint256));
            assertEq(gotRecipient, recipient);
            assertEq(gotAmount, amount);
            return;
        }
        revert("ProtocolFeeCharged not emitted");
    }

    function _signRewardRoots(
        ContestController c,
        address payer,
        address user,
        uint256 totalAmount,
        uint256 deadline,
        bytes32 referralNonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                referralGraph.REWARD_ROOTS_TYPEHASH(),
                c.referralGroupId(),
                c.referralRewardId(referralNonce),
                user,
                c.paymentToken(),
                totalAmount,
                payer,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", referralGraph.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(referralOracleKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _settleContestExpectRevert(
        ContestController c,
        uint256[] memory winningEntries,
        uint256[] memory payoutBps,
        bytes memory reason
    ) internal {
        uint256 secondaryWinner = winningEntries.length > 0 ? winningEntries[0] : 0;
        _settleContestExpectRevert(c, winningEntries, payoutBps, secondaryWinner, reason);
    }

    function _settleContestExpectRevert(
        ContestController c,
        uint256[] memory winningEntries,
        uint256[] memory payoutBps,
        uint256 secondaryWinner,
        bytes memory reason
    ) internal {
        if (c.state() == ContestController.ContestState.ACTIVE) {
            vm.prank(c.operator());
            c.lockContest();
        }
        (uint256 deadline, address oracle, bytes memory signature) =
            _referralAuth(c, _primaryWinnerEntry(winningEntries, payoutBps), bytes32(0));
        vm.prank(c.operator());
        vm.expectRevert(reason);
        c.settleContest(winningEntries, payoutBps, secondaryWinner, bytes32(0), deadline, oracle, signature);
    }

    /// @dev Activate if still OPEN so secondary buys succeed under ACTIVE-only gating.
    function _ensureActiveForSecondary(ContestController c) internal {
        if (c.state() == ContestController.ContestState.OPEN) {
            vm.prank(c.operator());
            c.activateContest();
        }
    }

    function _netBps(ContestController c) internal view returns (uint256) {
        return 10_000 - c.referralNetworkBps();
    }
}
