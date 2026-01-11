// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "solady/utils/MerkleProofLib.sol";

/**
 * @title PrimaryContest
 * @author MagRelo
 * @dev Library for managing primary contest mechanics (Layer 1)
 * 
 * Handles:
 * - Primary position addition/removal
 * - Primary payout claims
 * - Primary merkle root validation
 * - Primary-specific state management
 */
library PrimaryContest {
    /// @notice Denominator for basis point calculations
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ Events ============
    
    event PrimaryPositionAdded(address indexed owner, uint256 indexed entryId);
    event PrimaryPositionRemoved(uint256 indexed entryId, address indexed owner);
    event PrimaryPayoutClaimed(address indexed owner, uint256 indexed entryId, uint256 amount);
    event PrimaryMerkleRootUpdated(bytes32 newRoot);

    /**
     * @notice Validates merkle proof for primary position whitelist
     * @param merkleRoot Merkle root for primary position whitelist (bytes32(0) = no gating)
     * @param participant Address to verify
     * @param merkleProof Merkle proof for whitelist verification
     */
    function validatePrimaryMerkleProof(
        bytes32 merkleRoot,
        address participant,
        bytes32[] calldata merkleProof
    ) internal pure {
        if (merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(participant));
            require(MerkleProofLib.verify(merkleProof, merkleRoot, leaf), "Invalid merkle proof");
        }
    }

    /**
     * @notice Validates that entry can be added
     * @param entryOwner Storage mapping of entry ID to owner
     * @param entryId Entry ID to validate
     * @param expiryTimestamp Contest expiry timestamp
     * @param currentState Current contest state
     */
    function validateAddPrimaryPosition(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        uint256 expiryTimestamp,
        uint8 currentState // ContestState.OPEN = 0
    ) internal view {
        require(currentState == 0, "Contest not open"); // ContestState.OPEN
        require(entryOwner[entryId] == address(0), "Entry already exists");
        require(block.timestamp < expiryTimestamp, "Contest expired");
    }

    /**
     * @notice Validates that entry can be removed
     * @param entryOwner Storage mapping of entry ID to owner
     * @param entryId Entry ID to validate
     * @param owner Address claiming to be owner
     * @param currentState Current contest state
     */
    function validateRemovePrimaryPosition(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        address owner,
        uint8 currentState
    ) internal view {
        require(
            currentState == 0 || currentState == 4, // ContestState.OPEN or CANCELLED
            "Cannot withdraw - contest in progress or settled"
        );
        require(entryOwner[entryId] == owner, "Not entry owner");
    }

    /**
     * @notice Validates that payout can be claimed
     * @param entryOwner Storage mapping of entry ID to owner
     * @param entryId Entry ID to validate
     * @param owner Address claiming to be owner
     * @param currentState Current contest state
     * @param payout Prize pool payout for entry
     * @param bonus Position bonus for entry
     */
    function validateClaimPrimaryPayout(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        address owner,
        uint8 currentState, // ContestState.SETTLED = 3
        uint256 payout,
        uint256 bonus
    ) internal view {
        require(currentState == 3, "Contest not settled"); // ContestState.SETTLED
        require(entryOwner[entryId] == owner, "Not entry owner");
        require(payout + bonus > 0, "No payout");
    }

    /**
     * @notice Processes primary position addition
     * @param entries Storage array of entry IDs
     * @param entryOwner Storage mapping of entry ID to owner
     * @param primaryToSecondarySubsidy Storage mapping of entry to cross-subsidy amount
     * @param entryId Entry ID to add
     * @param owner Address of the primary participant
     * @param primaryDepositAmount Fixed deposit amount
     * @param oracleFee Oracle fee deducted from deposit
     * @param crossSubsidy Cross-subsidy amount redirected to secondary pool
     * @return primaryContribution Amount contributed to primary prize pool
     */
    function processAddPrimaryPosition(
        uint256[] storage entries,
        mapping(uint256 => address) storage entryOwner,
        mapping(uint256 => uint256) storage primaryToSecondarySubsidy,
        uint256 entryId,
        address owner,
        uint256 primaryDepositAmount,
        uint256 oracleFee,
        uint256 crossSubsidy
    ) internal returns (uint256 primaryContribution) {
        entries.push(entryId);
        entryOwner[entryId] = owner;

        uint256 netAmount = primaryDepositAmount - oracleFee;
        primaryContribution = netAmount - crossSubsidy;

        if (crossSubsidy > 0) {
            primaryToSecondarySubsidy[entryId] = crossSubsidy;
        }

        emit PrimaryPositionAdded(owner, entryId);
    }

    /**
     * @notice Processes primary position removal
     * @param entryOwner Storage mapping of entry ID to owner
     * @param primaryToSecondarySubsidy Storage mapping of entry to cross-subsidy amount
     * @param primaryPositionSubsidy Storage mapping of entry to position bonus
     * @param entryId Entry ID to remove
     * @param primaryDepositAmount Fixed deposit amount
     * @param oracleFee Oracle fee to reverse
     * @return refundAmount Full refund amount (primaryDepositAmount)
     * @return primaryContribution Amount to subtract from primary prize pool
     * @return crossSubsidy Cross-subsidy to reverse
     * @return bonus Position bonus to forfeit
     */
    function processRemovePrimaryPosition(
        mapping(uint256 => address) storage entryOwner,
        mapping(uint256 => uint256) storage primaryToSecondarySubsidy,
        mapping(uint256 => uint256) storage primaryPositionSubsidy,
        uint256 entryId,
        uint256 primaryDepositAmount,
        uint256 oracleFee
    ) internal returns (
        uint256 refundAmount,
        uint256 primaryContribution,
        uint256 crossSubsidy,
        uint256 bonus
    ) {
        // Mark entry as withdrawn by clearing owner
        address owner = entryOwner[entryId];
        entryOwner[entryId] = address(0);

        uint256 netAmount = primaryDepositAmount - oracleFee;
        crossSubsidy = primaryToSecondarySubsidy[entryId];
        primaryContribution = netAmount - crossSubsidy;

        if (crossSubsidy > 0) {
            primaryToSecondarySubsidy[entryId] = 0;
        }

        // Get position bonus to forfeit
        bonus = primaryPositionSubsidy[entryId];
        if (bonus > 0) {
            primaryPositionSubsidy[entryId] = 0;
        }

        refundAmount = primaryDepositAmount;
        emit PrimaryPositionRemoved(entryId, owner);
    }

    /**
     * @notice Processes primary payout claim
     * @param primaryPrizePoolPayouts Storage mapping of entry to payout amount
     * @param primaryPositionSubsidy Storage mapping of entry to position bonus
     * @param entryId Entry ID to claim for
     * @param owner Address claiming payout
     * @return totalClaim Total amount to claim (payout + bonus)
     * @return payout Prize pool payout amount
     * @return bonus Position bonus amount
     */
    function processClaimPrimaryPayout(
        mapping(uint256 => uint256) storage primaryPrizePoolPayouts,
        mapping(uint256 => uint256) storage primaryPositionSubsidy,
        uint256 entryId,
        address owner
    ) internal returns (
        uint256 totalClaim,
        uint256 payout,
        uint256 bonus
    ) {
        payout = primaryPrizePoolPayouts[entryId];
        bonus = primaryPositionSubsidy[entryId];
        totalClaim = payout + bonus;

        // Clear both payouts
        primaryPrizePoolPayouts[entryId] = 0;
        if (bonus > 0) {
            primaryPositionSubsidy[entryId] = 0;
        }

        emit PrimaryPayoutClaimed(owner, entryId, totalClaim);
    }
}
