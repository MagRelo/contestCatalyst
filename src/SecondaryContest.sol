// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "solady/utils/MerkleProofLib.sol";
import "./SecondaryPricing.sol";

/**
 * @title SecondaryContest
 * @author MagRelo
 * @dev Library for managing secondary contest mechanics (Layer 2)
 * 
 * Handles:
 * - Secondary position addition/removal
 * - Secondary payout claims
 * - ERC1155 token operations
 * - Secondary merkle root validation
 * 
 * Note: Pricing calculations are handled by SecondaryPricing library
 */
library SecondaryContest {
    /// @notice Denominator for basis point calculations
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ Events ============
    
    event SecondaryPositionAdded(
        address indexed participant, uint256 indexed entryId, uint256 amount, uint256 tokensReceived
    );
    event SecondaryPositionRemoved(address indexed participant, uint256 amount);
    event SecondaryPayoutClaimed(address indexed participant, uint256 indexed entryId, uint256 payout);
    event SecondaryMerkleRootUpdated(bytes32 newRoot);

    /**
     * @notice Validates merkle proof for secondary position whitelist
     * @param merkleRoot Merkle root for secondary position whitelist (bytes32(0) = no gating)
     * @param participant Address to verify
     * @param merkleProof Merkle proof for whitelist verification
     */
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

    /**
     * @notice Validates that secondary position can be added
     * @param entryOwner Storage mapping of entry ID to owner (for primary)
     * @param entryId Entry ID to validate
     * @param amount Deposit amount
     * @param currentState Current contest state
     */
    function validateAddSecondaryPosition(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        uint256 amount,
        uint8 currentState // ContestState.OPEN = 0, ACTIVE = 1
    ) internal view {
        require(currentState == 0 || currentState == 1, "Secondary positions not available"); // OPEN or ACTIVE
        require(entryOwner[entryId] != address(0), "Entry does not exist or withdrawn");
        require(amount > 0, "Amount must be > 0");
    }

    /**
     * @notice Validates that secondary position can be removed
     * @param entryOwner Storage mapping of entry ID to owner
     * @param entryId Entry ID to validate
     * @param tokenAmount Amount of tokens to burn
     * @param balance User's token balance
     * @param currentState Current contest state
     */
    function validateRemoveSecondaryPosition(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        uint256 tokenAmount,
        uint256 balance,
        uint8 currentState
    ) internal view {
        require(
            currentState == 0 || currentState == 4, // ContestState.OPEN or CANCELLED
            "Cannot withdraw - competition started or settled"
        );
        require(entryOwner[entryId] != address(0), "Entry does not exist");
        require(tokenAmount > 0, "Amount must be > 0");
        require(balance >= tokenAmount, "Insufficient balance");
    }

    /**
     * @notice Validates that secondary payout can be claimed
     * @param entryOwner Storage mapping of entry ID to owner
     * @param entryId Entry ID to validate
     * @param balance User's token balance
     * @param currentState Current contest state
     * @param secondaryMarketResolved Whether secondary market is resolved
     */
    function validateClaimSecondaryPayout(
        mapping(uint256 => address) storage entryOwner,
        uint256 entryId,
        uint256 balance,
        uint8 currentState, // ContestState.SETTLED = 3
        bool secondaryMarketResolved
    ) internal view {
        require(currentState == 3, "Contest not settled"); // ContestState.SETTLED
        require(secondaryMarketResolved, "Market not resolved");
        require(entryOwner[entryId] != address(0), "Entry does not exist or was withdrawn");
        require(balance > 0, "No tokens");
    }


    /**
     * @notice Processes secondary position addition
     * @param netPosition Storage mapping of entry to net position
     * @param primaryPositionSubsidy Storage mapping of entry to position bonus
     * @param secondaryToPrimarySubsidy Storage mapping of participant/entry to cross-subsidy
     * @param secondaryDepositedPerEntry Storage mapping of participant/entry to deposit amount
     * @param entryId Entry ID to add position on
     * @param participant Address of secondary participant
     * @param amount Total deposit amount
     * @param positionBonus Position bonus allocated to entry owner
     * @param crossSubsidy Cross-subsidy redirected to primary pool
     * @param tokensToMint Amount of ERC1155 tokens to mint (calculated by caller)
     */
    function processAddSecondaryPosition(
        mapping(uint256 => int256) storage netPosition,
        mapping(uint256 => uint256) storage primaryPositionSubsidy,
        mapping(address => mapping(uint256 => uint256)) storage secondaryToPrimarySubsidy,
        mapping(address => mapping(uint256 => uint256)) storage secondaryDepositedPerEntry,
        uint256 entryId,
        address participant,
        uint256 amount,
        uint256 positionBonus,
        uint256 crossSubsidy,
        uint256 tokensToMint
    ) internal {
        // Allocate position bonus to entry owner
        if (positionBonus > 0) {
            primaryPositionSubsidy[entryId] += positionBonus;
        }

        // Apply cross-subsidy
        if (crossSubsidy > 0) {
            secondaryToPrimarySubsidy[participant][entryId] += crossSubsidy;
        }

        // Track deposits per entry (for withdrawal refunds)
        secondaryDepositedPerEntry[participant][entryId] += amount;

        // Update demand tracking (tokens are calculated by caller using new pricing)
        netPosition[entryId] += int256(tokensToMint);

        emit SecondaryPositionAdded(participant, entryId, amount, tokensToMint);
    }

    /**
     * @notice Processes secondary position removal
     * @param netPosition Storage mapping of entry to net position
     * @param primaryPositionSubsidy Storage mapping of entry to position bonus
     * @param secondaryToPrimarySubsidy Storage mapping of participant/entry to cross-subsidy
     * @param secondaryDepositedPerEntry Storage mapping of participant/entry to deposit amount
     * @param entryId Entry ID to remove position from
     * @param participant Address of secondary participant
     * @param tokenAmount Amount of tokens to burn
     * @param userTotalTokens User's total token balance for this entry
     * @param positionBonus Position bonus to reverse
     * @param crossRefund Cross-subsidy to reverse
     * @return refundAmount Full refund amount
     */
    function processRemoveSecondaryPosition(
        mapping(uint256 => int256) storage netPosition,
        mapping(uint256 => uint256) storage primaryPositionSubsidy,
        mapping(address => mapping(uint256 => uint256)) storage secondaryToPrimarySubsidy,
        mapping(address => mapping(uint256 => uint256)) storage secondaryDepositedPerEntry,
        uint256 entryId,
        address participant,
        uint256 tokenAmount,
        uint256 userTotalTokens,
        uint256 positionBonus,
        uint256 crossRefund,
        uint256 /* collateral */
    ) internal returns (uint256 refundAmount) {
        // Reverse position bonus allocation
        if (positionBonus > 0) {
            primaryPositionSubsidy[entryId] -= positionBonus;
        }

        // Calculate refund amount
        uint256 depositedOnEntry = secondaryDepositedPerEntry[participant][entryId];
        refundAmount = (depositedOnEntry * tokenAmount) / userTotalTokens;
        secondaryDepositedPerEntry[participant][entryId] -= refundAmount;

        // Reverse cross-subsidy
        if (crossRefund > 0) {
            secondaryToPrimarySubsidy[participant][entryId] -= crossRefund;
        }

        // Update net position (tokens will be burned by caller)
        netPosition[entryId] -= int256(tokenAmount);

        emit SecondaryPositionRemoved(participant, refundAmount);
    }

    /**
     * @notice Processes secondary payout claim
     * @param netPosition Storage mapping of entry to net position
     * @param entryId Entry ID to claim for
     * @param participant Address claiming payout
     * @param balance User's token balance
     * @param secondaryWinningEntry Winning entry ID
     * @param secondaryPrizePool Current secondary prize pool
     * @param secondaryPrizePoolSubsidy Current secondary prize pool subsidy
     * @param availableBalance Available balance for safety check
     * @return payout Amount to pay out
     * @return shouldSweepDust Whether to sweep remaining dust
     * @return fromBasePool Amount to subtract from base pool
     * @return fromSubsidyPool Amount to subtract from subsidy pool
     */
    function processClaimSecondaryPayout(
        mapping(uint256 => int256) storage netPosition,
        uint256 entryId,
        address participant,
        uint256 balance,
        uint256 secondaryWinningEntry,
        uint256 secondaryPrizePool,
        uint256 secondaryPrizePoolSubsidy,
        uint256 availableBalance
    ) internal returns (uint256 payout, bool shouldSweepDust, uint256 fromBasePool, uint256 fromSubsidyPool) {
        uint256 totalSupplyBefore = uint256(netPosition[entryId]);
        
        // Winner-take-all: only winning entry gets paid
        if (entryId == secondaryWinningEntry && totalSupplyBefore > 0) {
            // Winners split ALL secondary collateral (base + subsidy)
            uint256 totalSecondaryFunds = secondaryPrizePool + secondaryPrizePoolSubsidy;
            payout = (balance * totalSecondaryFunds) / totalSupplyBefore;

            // Safety check
            if (payout > availableBalance) {
                payout = availableBalance;
            }

            if (payout > 0 && totalSecondaryFunds > 0) {
                // Calculate pool reductions - caller will apply them
                fromBasePool = (payout * secondaryPrizePool) / totalSecondaryFunds;
                fromSubsidyPool = payout - fromBasePool;
            }

            // Update net position (tokens will be burned by caller)
            netPosition[entryId] -= int256(balance);

            // Check if this was the last claim (no supply remains)
            uint256 remainingSupply = uint256(netPosition[entryId]);
            if (remainingSupply == 0) {
                shouldSweepDust = true;
            }
        }

        emit SecondaryPayoutClaimed(participant, entryId, payout);
    }
}
