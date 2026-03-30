// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "solady/utils/MerkleProofLib.sol";

/**
 * @title PrimaryContest
 * @author MagRelo
 * @dev Library for managing primary contest mechanics (Layer 1)
 */
library PrimaryContest {
    /// @notice Denominator for basis point calculations
    uint256 public constant BPS_DENOMINATOR = 10000;

    event PrimaryPositionAdded(address indexed owner, uint256 indexed entryId);
    event PrimaryPositionRemoved(uint256 indexed entryId, address indexed owner);
    event PrimaryPayoutClaimed(address indexed owner, uint256 indexed entryId, uint256 amount);
    event PrimaryMerkleRootUpdated(bytes32 newRoot);

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

    function validateAddPrimaryPosition(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        uint256 expiryTimestamp,
        uint8 currentState
    ) internal view {
        require(currentState == 0, "Contest not open");
        require(entryOwner[entryId] == address(0), "Entry already exists");
        require(block.timestamp < expiryTimestamp, "Contest expired");
    }

    function validateRemovePrimaryPosition(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        address owner,
        uint8 currentState
    ) internal view {
        require(
            currentState == 0 || currentState == 4,
            "Cannot withdraw - contest in progress or settled"
        );
        require(entryOwner[entryId] == owner, "Not entry owner");
    }

    function validateClaimPrimaryPayout(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        address owner,
        uint8 currentState,
        uint256 payout
    ) internal view {
        require(currentState == 3, "Contest not settled");
        require(entryOwner[entryId] == owner, "Not entry owner");
        require(payout > 0, "No payout");
    }

    /**
     * @notice Full primary deposit goes to primary prize pool (no cross-subsidy)
     */
    function processAddPrimaryPosition(
        uint256[] storage entries,
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        address owner,
        uint256 /* primaryDepositAmount */
    ) internal {
        entries.push(entryId);
        entryOwner[entryId] = owner;
        emit PrimaryPositionAdded(owner, entryId);
    }

    function processRemovePrimaryPosition(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        uint256 primaryDepositAmount
    ) internal returns (uint256 refundAmount, uint256 primaryContribution) {
        address owner = entryOwner[entryId];
        entryOwner[entryId] = address(0);
        primaryContribution = primaryDepositAmount;
        refundAmount = primaryDepositAmount;
        emit PrimaryPositionRemoved(entryId, owner);
    }

    function processClaimPrimaryPayout(mapping(uint256 => uint256) storage primaryPrizePoolPayouts, uint256 entryId)
        internal
        returns (uint256 payout)
    {
        payout = primaryPrizePoolPayouts[entryId];
        primaryPrizePoolPayouts[entryId] = 0;
    }
}
