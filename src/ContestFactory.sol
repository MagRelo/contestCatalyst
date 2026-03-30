// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ContestController.sol";

/**
 * @title ContestFactory
 * @dev Factory for creating ContestController instances
 */
contract ContestFactory {
    address[] public contests;
    mapping(address => address) public contestHost;

    event ContestCreated(address indexed contest, address indexed host, uint256 contestantDepositAmount);

    /**
     * @param primaryEntryInvestmentShareBps BPS of each secondary buy for entry-owner curve leg (0–10000)
     */
    function createContest(
        address paymentToken,
        address oracle,
        uint256 contestantDepositAmount,
        uint256 oracleFee,
        uint256 expiry,
        uint256 primaryEntryInvestmentShareBps
    ) external returns (address) {
        ContestController contest = new ContestController(
            paymentToken,
            oracle,
            contestantDepositAmount,
            oracleFee,
            expiry,
            primaryEntryInvestmentShareBps
        );

        address contestAddress = address(contest);
        contests.push(contestAddress);
        contestHost[contestAddress] = msg.sender;

        emit ContestCreated(contestAddress, msg.sender, contestantDepositAmount);

        return contestAddress;
    }

    function getContests() external view returns (address[] memory) {
        return contests;
    }

    function getContestCount() external view returns (uint256) {
        return contests.length;
    }
}
