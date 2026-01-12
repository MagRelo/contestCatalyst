// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ContestController.sol";

/**
 * @title ContestFactory
 * @author MagRelo
 * @dev Factory contract for creating Contest contracts
 *
 * This contract provides a centralized way to create and manage Contest contracts.
 * Each Contest combines Layer 1 (contestant competition) and Layer 2 (spectator predictions).
 *
 * @custom:security All contest contracts created through this factory can be tracked
 */
contract ContestFactory {
    /// @notice Array of all created contest contract addresses
    address[] public contests;

    /// @notice Mapping to track which address created each contest
    mapping(address => address) public contestHost;

    /// @notice Emitted when a new contest contract is created
    /// @param contest Address of the newly created contest contract
    /// @param host Address of the creator
    /// @param contestantDepositAmount Required deposit amount for contestants
    event ContestCreated(address indexed contest, address indexed host, uint256 contestantDepositAmount);

    /**
     * @notice Creates a new Contest contract
     * @param paymentToken The ERC20 token used for deposits (typically PlatformToken/CUT)
     * @param oracle The address that will control the contest
     * @param contestantDepositAmount The amount each contestant must deposit
     * @param oracleFee The fee percentage for the oracle (in basis points, max 1000 = 10%)
     * @param expiry The expiration timestamp for the contest
     * @param positionBonusShareBps Portion of accumulated subsidy going to position bonuses (e.g., 5000 = 50%)
     * @param targetPrimaryShareBps Target share (in basis points) to allocate to the primary side across deposits
     * @param maxCrossSubsidyBps Maximum share (in basis points) of any deposit that can be redirected to the opposite pool
     * @return The address of the newly created Contest contract
     *
     * Note: paymentToken is typically the PlatformToken (CUT) address
     *
     * Requirements:
     * - paymentToken must not be zero address
     * - oracle must not be zero address
     * - contestantDepositAmount must be greater than 0
     * - expiry must be in the future
     * - positionBonusShareBps must be <= 100% (portion of subsidy)
     *
     * Emits a {ContestCreated} event
     */
    function createContest(
        address paymentToken,
        address oracle,
        uint256 contestantDepositAmount,
        uint256 oracleFee,
        uint256 expiry,
        uint256 positionBonusShareBps,
        uint256 targetPrimaryShareBps,
        uint256 maxCrossSubsidyBps
    ) external returns (address) {
        ContestController contest = new ContestController(
            paymentToken,
            oracle,
            contestantDepositAmount,
            oracleFee,
            expiry,
            positionBonusShareBps,
            targetPrimaryShareBps,
            maxCrossSubsidyBps
        );

        address contestAddress = address(contest);
        contests.push(contestAddress);
        contestHost[contestAddress] = msg.sender;

        emit ContestCreated(contestAddress, msg.sender, contestantDepositAmount);

        return contestAddress;
    }

    /**
     * @notice Returns all created contest addresses
     * @return Array of contest contract addresses
     */
    function getContests() external view returns (address[] memory) {
        return contests;
    }

    /**
     * @notice Get total number of contests created
     * @return Total contest count
     */
    function getContestCount() external view returns (uint256) {
        return contests.length;
    }
}
