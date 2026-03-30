// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "solady/utils/MerkleProofLib.sol";

/**
 * @title SecondaryContest
 * @author MagRelo
 * @dev Library for managing secondary contest mechanics (Layer 2)
 */
library SecondaryContest {
    uint256 public constant BPS_DENOMINATOR = 10000;

    event SecondaryPositionAdded(
        address indexed participant,
        uint256 indexed entryId,
        uint256 amount,
        uint256 participantTokensReceived,
        uint256 primaryEntryInvestment,
        uint256 ownerTokensReceived
    );
    event SecondaryPositionSold(address indexed participant, uint256 indexed entryId, uint256 tokenAmount, uint256 proceeds);
    event SecondaryPayoutClaimed(address indexed participant, uint256 indexed entryId, uint256 payout);
    event SecondaryMerkleRootUpdated(bytes32 newRoot);

    function validateSecondaryMerkleProof(
        bytes32 merkleRoot,
        address participant,
        bytes32[] calldata merkleProof
    ) internal pure {
        if (merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(participant));
            require(MerkleProofLib.verify(merkleProof, merkleRoot, leaf), "Invalid merkle proof");
        }
    }

    function validateAddSecondaryPosition(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        uint256 amount,
        uint8 currentState
    ) internal view {
        require(currentState == 0 || currentState == 1, "Secondary positions not available");
        require(entryOwner[entryId] != address(0), "Entry does not exist or withdrawn");
        require(amount > 0, "Amount must be > 0");
    }

    function validateRemoveSecondaryPosition(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        uint256 tokenAmount,
        uint256 balance,
        uint8 currentState
    ) internal view {
        require(
            currentState == 0 || currentState == 4,
            "Cannot withdraw - competition started or settled"
        );
        require(entryOwner[entryId] != address(0), "Entry does not exist");
        require(tokenAmount > 0, "Amount must be > 0");
        require(balance >= tokenAmount, "Insufficient balance");
    }

    function validateClaimSecondaryPayout(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        uint256 balance,
        uint8 currentState,
        bool secondaryMarketResolved,
        uint256 secondaryWinningEntry
    ) internal view {
        require(currentState == 3, "Contest not settled");
        require(secondaryMarketResolved, "Market not resolved");
        require(entryId == secondaryWinningEntry, "Not winning entry");
        require(entryOwner[entryId] != address(0), "Entry does not exist or was withdrawn");
        require(balance > 0, "No tokens");
    }

    function processAddSecondaryPosition(
        mapping(uint256 => int256) storage netPosition,
        uint256 entryId,
        address participant,
        uint256 amount,
        uint256 primaryEntryInvestment,
        uint256 ownerTokensReceived,
        uint256 participantTokensReceived
    ) internal {
        netPosition[entryId] += int256(ownerTokensReceived + participantTokensReceived);
        emit SecondaryPositionAdded(
            participant, entryId, amount, participantTokensReceived, primaryEntryInvestment, ownerTokensReceived
        );
    }

    function processRemoveSecondaryPosition(
        mapping(uint256 => int256) storage netPosition,
        uint256 entryId,
        address participant,
        uint256 tokenAmount,
        uint256 proceeds
    ) internal {
        netPosition[entryId] -= int256(tokenAmount);
        emit SecondaryPositionSold(participant, entryId, tokenAmount, proceeds);
    }

}
