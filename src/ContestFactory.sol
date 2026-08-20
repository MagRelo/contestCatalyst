// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ContestController.sol";

/**
 * @title ContestFactory
 * @dev Factory for creating ContestController instances.
 *      `paymentToken`, `operator`, `referralGraph`, `rewardCalculator`, and `referralGroupId`
 *      are factory-level immutables so permissionless `createContest` callers cannot choose
 *      the trust surface or payment asset.
 */
contract ContestFactory {
    address public immutable paymentToken;
    address public immutable operator;
    address public immutable referralGraph;
    address public immutable rewardCalculator;
    bytes32 public immutable referralGroupId;

    address[] public contests;
    mapping(address => address) public contestHost;

    event ContestCreated(
        address indexed contest,
        address indexed host,
        uint256 contestantDepositAmount,
        address paymentToken,
        address operator,
        address referralGraph,
        address rewardCalculator,
        bytes32 referralGroupId,
        uint256 referralNetworkBps,
        uint256 expiry,
        uint256 primaryDepositSecondarySubsidyBps
    );

    constructor(
        address _paymentToken,
        address _operator,
        address _referralGraph,
        address _rewardCalculator,
        bytes32 _referralGroupId
    ) {
        require(_paymentToken != address(0), "Invalid payment token");
        require(_operator != address(0), "Invalid operator");
        require(_referralGraph != address(0), "Invalid referral graph");
        require(_rewardCalculator != address(0), "Invalid reward calculator");
        paymentToken = _paymentToken;
        operator = _operator;
        referralGraph = _referralGraph;
        rewardCalculator = _rewardCalculator;
        referralGroupId = _referralGroupId;
    }

    function createContest(
        uint256 contestantDepositAmount,
        uint256 referralNetworkBps,
        uint256 expiry,
        uint256 primaryDepositSecondarySubsidyBps
    ) external returns (address) {
        ContestController contest = new ContestController(
            paymentToken,
            operator,
            contestantDepositAmount,
            referralNetworkBps,
            expiry,
            primaryDepositSecondarySubsidyBps,
            referralGraph,
            rewardCalculator,
            referralGroupId
        );

        address contestAddress = address(contest);
        contests.push(contestAddress);
        contestHost[contestAddress] = msg.sender;

        emit ContestCreated(
            contestAddress,
            msg.sender,
            contestantDepositAmount,
            paymentToken,
            operator,
            referralGraph,
            rewardCalculator,
            referralGroupId,
            referralNetworkBps,
            expiry,
            primaryDepositSecondarySubsidyBps
        );

        return contestAddress;
    }

    function getContests() external view returns (address[] memory) {
        return contests;
    }

    function getContestCount() external view returns (uint256) {
        return contests.length;
    }
}
