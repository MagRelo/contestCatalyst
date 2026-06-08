// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "solmate/tokens/ERC1155.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "solmate/utils/SafeTransferLib.sol";
import "./PrimaryContest.sol";
import "./SecondaryContest.sol";
import "./SecondaryPricing.sol";
import "referralTree/interfaces/IRewardDistributor.sol";
import "referralTree/interfaces/IReferralGraph.sol";

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title ContestController
 * @dev Layer 1: primary prize pool (deposit minus optional subsidy carve). Layer 2: per-entry bonding
 *      curve; each buy credits `secondaryLiquidityPerEntry[entryId]` (backed) for OPEN/CANCELLED
 *      sell-back pricing. Primary carve credits `secondaryPrimarySubsidyPerEntry[entryId]` (unbacked);
 *      sell-backs use backed liquidity only.
 *      On settlement, all per-entry secondary balances are merged into `secondaryLiquidityPerEntry[secondaryWinningEntry]`
 *      so winning-entry ERC1155 holders redeem pro-rata against the full secondary TVL (or it spills to primary payouts
 *      if there is no supply on the winning entry). Each secondary buy credits liquidity and mints ERC1155 to the caller per the bonding curve from the entry's current nonnegative supply.
 */
contract ContestController is ERC1155, ReentrancyGuard {
    address public constant REFERRAL_ROOT = address(0x0000000000000000000000000000000000000001);

    address public immutable paymentToken;
    address public immutable oracle;
    uint256 public immutable primaryDepositAmount;
    uint256 public immutable referralNetworkBps;
    uint256 public immutable expiryTimestamp;
    /// @notice BPS of each primary deposit credited to `secondaryPrimarySubsidyPerEntry` (no ERC1155 mint)
    uint256 public immutable primaryDepositSecondarySubsidyBps;
    address public immutable rewardDistributor;
    bytes32 public immutable referralGroupId;

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant PRICE_PRECISION = 1e6;

    enum ContestState {
        OPEN,
        ACTIVE,
        LOCKED,
        SETTLED,
        CANCELLED,
        CLOSED
    }

    ContestState public state;

    uint256[] public entries;
    /// @dev Index in `entries` plus one; zero means not currently active.
    mapping(uint256 => uint256) private entryIndexPlusOne;
    mapping(uint256 => address) public entryOwner;
    uint256 public primaryPrizePool;
    mapping(uint256 => uint256) public primaryPrizePoolPayouts;
    bytes32 public primaryMerkleRoot;

    mapping(uint256 => int256) public netPosition;
    /// @notice Payment token backing this entry's secondary ERC1155 (secondary buy/sell only; sell-backs are pro-rata on this bucket while OPEN/CANCELLED)
    /// @dev After SETTLE, per-entry backed + subsidy are merged into the winning entry's slot for redemption accounting.
    mapping(uint256 => uint256) public secondaryLiquidityPerEntry;

    /// @notice Primary-sourced secondary TVL on this entry (no share backing; not used for OPEN/CANCELLED sell-backs)
    mapping(uint256 => uint256) public secondaryPrimarySubsidyPerEntry;

    /// @notice Attributed invested principal per token holder per entry (used by frontend UI)
    /// @dev Updated on secondary buys and reduced pro-rata on sells; not used for pricing.
    mapping(address => mapping(uint256 => uint256)) public secondaryDepositedPerEntry;

    uint256 public secondaryWinningEntry;
    bool public secondaryMarketResolved;
    bytes32 public secondaryMerkleRoot;

    event PrimaryPositionAdded(address indexed owner, uint256 indexed entryId);
    event PrimaryPositionRemoved(uint256 indexed entryId, address indexed owner);
    event PrimaryPayoutClaimed(address indexed owner, uint256 indexed entryId, uint256 amount);
    event PrimaryMerkleRootUpdated(bytes32 newRoot);

    event SecondaryPositionAdded(
        address indexed participant,
        uint256 indexed entryId,
        uint256 amount,
        uint256 participantTokensReceived
    );
    event SecondaryPositionSold(address indexed participant, uint256 indexed entryId, uint256 tokenAmount, uint256 proceeds);
    event SecondaryPayoutClaimed(address indexed participant, uint256 indexed entryId, uint256 payout);
    event SecondaryMerkleRootUpdated(bytes32 newRoot);

    event ContestActivated();
    event ContestLocked();
    event ContestSettled(uint256[] winningEntries, uint256[] payouts);
    event ContestCancelled();
    event ContestClosed();

    event ReferralNetworkFeeDistributed(
        address indexed winner, address indexed payoutAnchor, uint256 amount, bytes32 eventId
    );
    event ReferralNetworkFeeToOracle(address indexed winner, uint256 amount);

    modifier onlyOracle() {
        require(msg.sender == oracle, "Not oracle");
        _;
    }

    constructor(
        address _paymentToken,
        address _oracle,
        uint256 _primaryDepositAmount,
        uint256 _referralNetworkBps,
        uint256 _expiryTimestamp,
        uint256 _primaryDepositSecondarySubsidyBps,
        address _rewardDistributor,
        bytes32 _referralGroupId
    ) ERC1155() {
        require(_paymentToken != address(0), "Invalid payment token");
        require(_oracle != address(0), "Invalid oracle");
        require(_referralNetworkBps <= 1000, "Referral network fee too high");
        require(_expiryTimestamp > block.timestamp, "Expiry in past");
        require(_primaryDepositSecondarySubsidyBps <= BPS_DENOMINATOR, "Subsidy bps too high");
        require(_rewardDistributor != address(0), "Invalid reward distributor");

        paymentToken = _paymentToken;
        oracle = _oracle;
        primaryDepositAmount = _primaryDepositAmount;
        referralNetworkBps = _referralNetworkBps;
        expiryTimestamp = _expiryTimestamp;
        primaryDepositSecondarySubsidyBps = _primaryDepositSecondarySubsidyBps;
        rewardDistributor = _rewardDistributor;
        referralGroupId = _referralGroupId;

        state = ContestState.OPEN;
    }

    function addPrimaryPosition(uint256 entryId, bytes32[] calldata merkleProof) external nonReentrant {
        PrimaryContest.validatePrimaryMerkleProof(primaryMerkleRoot, msg.sender, merkleProof);
        PrimaryContest.validateAddPrimaryPosition(entryOwner, entryId, expiryTimestamp, uint8(state));
        require(entryIndexPlusOne[entryId] == 0, "Entry already active");

        PrimaryContest.processAddPrimaryPosition(entries, entryOwner, entryId, msg.sender, primaryDepositAmount);
        entryIndexPlusOne[entryId] = entries.length;

        (uint256 toPrimaryPool, uint256 subsidy) = _splitPrimaryDeposit(primaryDepositAmount);
        primaryPrizePool += toPrimaryPool;
        if (subsidy > 0) {
            secondaryPrimarySubsidyPerEntry[entryId] += subsidy;
        }

        SafeTransferLib.safeTransferFrom(ERC20(paymentToken), msg.sender, address(this), primaryDepositAmount);
    }

    function removePrimaryPosition(uint256 entryId) external nonReentrant {
        PrimaryContest.validateRemovePrimaryPosition(entryOwner, entryId, msg.sender, uint8(state));

        (uint256 refundAmount,) = PrimaryContest.processRemovePrimaryPosition(entryOwner, entryId, primaryDepositAmount);
        _removeActiveEntry(entryId);

        (uint256 toPrimaryPool, uint256 subsidyPortion) = _splitPrimaryDeposit(primaryDepositAmount);
        primaryPrizePool -= toPrimaryPool;
        require(secondaryPrimarySubsidyPerEntry[entryId] >= subsidyPortion, "Subsidy underflow");
        secondaryPrimarySubsidyPerEntry[entryId] -= subsidyPortion;

        SafeTransferLib.safeTransfer(ERC20(paymentToken), msg.sender, refundAmount);
    }

    function claimPrimaryPayout(uint256 entryId) external nonReentrant {
        PrimaryContest.validateClaimPrimaryPayout(
            entryOwner, entryId, msg.sender, uint8(state), primaryPrizePoolPayouts[entryId]
        );

        uint256 payout = PrimaryContest.processClaimPrimaryPayout(primaryPrizePoolPayouts, entryId);

        if (primaryPrizePool >= payout) {
            primaryPrizePool -= payout;
        } else {
            primaryPrizePool = 0;
        }

        SafeTransferLib.safeTransfer(ERC20(paymentToken), msg.sender, payout);
        emit PrimaryPayoutClaimed(msg.sender, entryId, payout);
    }

    function addSecondaryPosition(uint256 entryId, uint256 amount, bytes32[] calldata merkleProof)
        external
        nonReentrant
    {
        SecondaryContest.validateSecondaryMerkleProof(secondaryMerkleRoot, msg.sender, merkleProof);
        SecondaryContest.validateAddSecondaryPosition(entryOwner, entryId, amount, uint8(state));

        int256 netPos = netPosition[entryId];
        uint256 shares0 = netPos > 0 ? uint256(netPos) : 0;

        uint256 buyerTokens = SecondaryPricing.calculateTokensFromCollateral(shares0, amount);
        require(buyerTokens > 0, "Payment too small: insufficient to purchase tokens");

        secondaryLiquidityPerEntry[entryId] += amount;

        SecondaryContest.processAddSecondaryPosition(netPosition, entryId, msg.sender, amount, buyerTokens);

        secondaryDepositedPerEntry[msg.sender][entryId] += amount;
        _mint(msg.sender, entryId, buyerTokens, "");

        SafeTransferLib.safeTransferFrom(ERC20(paymentToken), msg.sender, address(this), amount);
    }

    /// @notice Pro-rata sell-back of secondary tokens (OPEN or CANCELLED only)
    function removeSecondaryPosition(uint256 entryId, uint256 tokenAmount) external nonReentrant {
        uint256 userBal = balanceOf[msg.sender][entryId];

        SecondaryContest.validateRemoveSecondaryPosition(
            entryOwner, entryId, tokenAmount, userBal, uint8(state)
        );

        uint256 supply = uint256(netPosition[entryId]);
        require(supply > 0, "No supply");

        uint256 liquidity = secondaryLiquidityPerEntry[entryId];
        uint256 cashOut = (tokenAmount * liquidity) / supply;

        uint256 available = IERC20Balance(paymentToken).balanceOf(address(this));
        if (cashOut > available) {
            cashOut = available;
        }

        uint256 depositedOnEntry = secondaryDepositedPerEntry[msg.sender][entryId];
        if (depositedOnEntry > 0) {
            uint256 principalToForfeit = (depositedOnEntry * tokenAmount) / userBal;
            secondaryDepositedPerEntry[msg.sender][entryId] = depositedOnEntry - principalToForfeit;
        }

        _burn(msg.sender, entryId, tokenAmount);

        SecondaryContest.processRemoveSecondaryPosition(netPosition, entryId, msg.sender, tokenAmount, cashOut);

        if (cashOut > 0) {
            if (secondaryLiquidityPerEntry[entryId] >= cashOut) {
                secondaryLiquidityPerEntry[entryId] -= cashOut;
            } else {
                secondaryLiquidityPerEntry[entryId] = 0;
            }
            SafeTransferLib.safeTransfer(ERC20(paymentToken), msg.sender, cashOut);
        }
    }

    function claimSecondaryPayout(uint256 entryId) external nonReentrant {
        uint256 balance = balanceOf[msg.sender][entryId];

        SecondaryContest.validateClaimSecondaryPayout(
            entryOwner,
            entryId,
            balance,
            uint8(state),
            secondaryMarketResolved,
            secondaryWinningEntry
        );

        uint256 totalSupplyBefore = uint256(netPosition[entryId]);
        require(totalSupplyBefore > 0, "No supply");

        uint256 entryLiquidity = secondaryLiquidityPerEntry[entryId];
        uint256 payout = entryLiquidity > 0 ? (balance * entryLiquidity) / totalSupplyBefore : 0;

        uint256 available = IERC20Balance(paymentToken).balanceOf(address(this));
        if (payout > available) {
            payout = available;
        }

        _burn(msg.sender, entryId, balance);
        netPosition[entryId] -= int256(balance);

        secondaryDepositedPerEntry[msg.sender][entryId] = 0;

        if (payout > 0) {
            if (secondaryLiquidityPerEntry[entryId] >= payout) {
                secondaryLiquidityPerEntry[entryId] -= payout;
            } else {
                secondaryLiquidityPerEntry[entryId] = 0;
            }
            SafeTransferLib.safeTransfer(ERC20(paymentToken), msg.sender, payout);
            emit SecondaryPayoutClaimed(msg.sender, entryId, payout);
        } else {
            emit SecondaryPayoutClaimed(msg.sender, entryId, 0);
        }

        if (uint256(netPosition[entryId]) == 0) {
            uint256 remaining = IERC20Balance(paymentToken).balanceOf(address(this));
            if (remaining > 0) {
                secondaryLiquidityPerEntry[entryId] = 0;
                SafeTransferLib.safeTransfer(ERC20(paymentToken), msg.sender, remaining);
            }
        }
    }

    function activateContest() external onlyOracle {
        require(state == ContestState.OPEN, "Contest already started");
        require(entries.length > 0, "No entries");
        state = ContestState.ACTIVE;
        emit ContestActivated();
    }

    function lockContest() external onlyOracle {
        require(state == ContestState.ACTIVE, "Contest not active");
        state = ContestState.LOCKED;
        emit ContestLocked();
    }

    function settleContest(
        uint256[] calldata winningEntries,
        uint256[] calldata payoutBps,
        IRewardDistributor.ChainRewardData calldata referralReward,
        bytes calldata referralSignature
    ) external onlyOracle nonReentrant {
        require(state == ContestState.ACTIVE || state == ContestState.LOCKED, "Contest not active or locked");
        require(winningEntries.length > 0, "Must have at least one winner");
        require(winningEntries.length == payoutBps.length, "Array length mismatch");
        require(winningEntries.length <= entries.length, "Too many winners");

        uint256 totalBps = 0;
        for (uint256 i = 0; i < payoutBps.length; i++) {
            require(payoutBps[i] > 0, "Use non-zero payouts only");
            totalBps += payoutBps[i];
        }
        require(totalBps == BPS_DENOMINATOR, "Payouts must sum to 100%");

        uint256 totalPrimary = primaryPrizePool;
        uint256 totalSecondary;
        for (uint256 j = 0; j < entries.length; j++) {
            uint256 eid = entries[j];
            totalSecondary += secondaryLiquidityPerEntry[eid] + secondaryPrimarySubsidyPerEntry[eid];
        }
        uint256 totalGross = totalPrimary + totalSecondary;

        uint256 referralFee;
        uint256 netBps = BPS_DENOMINATOR;
        if (referralNetworkBps > 0 && totalGross > 0) {
            referralFee = (totalGross * referralNetworkBps) / BPS_DENOMINATOR;
            netBps = BPS_DENOMINATOR - referralNetworkBps;
        }
        uint256 netPrimary = (totalPrimary * netBps) / BPS_DENOMINATOR;
        uint256 netSecondary = (totalSecondary * netBps) / BPS_DENOMINATOR;

        if (referralFee > 0) {
            address winner = entryOwner[winningEntries[0]];
            require(winner != address(0), "Invalid winner");

            IReferralGraph referralGraph =
                IRewardDistributor(rewardDistributor).getReferralGraph();
            address payoutAnchor = referralGraph.getReferrer(winner, referralGroupId);

            if (payoutAnchor != address(0) && payoutAnchor != REFERRAL_ROOT) {
                require(referralReward.totalAmount == referralFee, "Referral amount mismatch");
                require(referralReward.user == payoutAnchor, "Referral user mismatch");
                require(referralReward.rewardToken == paymentToken, "Referral token mismatch");
                require(referralReward.groupId == referralGroupId, "Referral group mismatch");

                SafeTransferLib.safeTransfer(ERC20(paymentToken), rewardDistributor, referralFee);
                IRewardDistributor(rewardDistributor).distributeChainRewards(referralReward, referralSignature);

                emit ReferralNetworkFeeDistributed(winner, payoutAnchor, referralFee, referralReward.eventId);
            } else {
                SafeTransferLib.safeTransfer(ERC20(paymentToken), oracle, referralFee);
                emit ReferralNetworkFeeToOracle(winner, referralFee);
            }
        }

        state = ContestState.SETTLED;

        primaryPrizePool = netPrimary;
        for (uint256 i = 0; i < winningEntries.length; i++) {
            uint256 entryId = winningEntries[i];
            uint256 payout = (netPrimary * payoutBps[i]) / BPS_DENOMINATOR;
            primaryPrizePoolPayouts[entryId] = payout;
        }

        secondaryWinningEntry = winningEntries[0];
        secondaryMarketResolved = true;

        for (uint256 k = 0; k < entries.length; k++) {
            uint256 eid = entries[k];
            secondaryLiquidityPerEntry[eid] = 0;
            secondaryPrimarySubsidyPerEntry[eid] = 0;
        }
        secondaryLiquidityPerEntry[secondaryWinningEntry] = netSecondary;

        uint256 winnerSupply = uint256(netPosition[secondaryWinningEntry]);
        uint256 winnerLiq = secondaryLiquidityPerEntry[secondaryWinningEntry];
        if (winnerLiq > 0 && winnerSupply == 0) {
            uint256 poolToDistribute = winnerLiq;
            secondaryLiquidityPerEntry[secondaryWinningEntry] = 0;
            uint256 distributed = 0;
            for (uint256 i = 0; i < winningEntries.length; i++) {
                uint256 eid = winningEntries[i];
                uint256 extra = (poolToDistribute * payoutBps[i]) / BPS_DENOMINATOR;
                if (extra > 0) {
                    distributed += extra;
                    primaryPrizePoolPayouts[eid] += extra;
                }
            }
            if (distributed < poolToDistribute) {
                primaryPrizePoolPayouts[winningEntries[0]] += poolToDistribute - distributed;
            }
        }

        emit ContestSettled(winningEntries, payoutBps);
    }

    function cancelContest() external onlyOracle {
        require(state != ContestState.SETTLED && state != ContestState.CLOSED, "Contest settled - cannot cancel");
        state = ContestState.CANCELLED;
        emit ContestCancelled();
    }

    function closeContest() external onlyOracle nonReentrant {
        require(block.timestamp >= expiryTimestamp, "Expiry not reached");

        uint256 remaining = IERC20Balance(paymentToken).balanceOf(address(this));
        if (remaining > 0) {
            primaryPrizePool = 0;
            for (uint256 i = 0; i < entries.length; i++) {
                uint256 eid = entries[i];
                secondaryLiquidityPerEntry[eid] = 0;
                secondaryPrimarySubsidyPerEntry[eid] = 0;
            }

            state = ContestState.CLOSED;
            SafeTransferLib.safeTransfer(ERC20(paymentToken), oracle, remaining);
            emit ContestClosed();
        }
    }

    function setPrimaryMerkleRoot(bytes32 _root) external onlyOracle {
        primaryMerkleRoot = _root;
        emit PrimaryMerkleRootUpdated(_root);
    }

    function setSecondaryMerkleRoot(bytes32 _root) external onlyOracle {
        secondaryMerkleRoot = _root;
        emit SecondaryMerkleRootUpdated(_root);
    }

    function cancelExpired() external {
        require(block.timestamp >= expiryTimestamp, "Not expired");
        require(state != ContestState.SETTLED && state != ContestState.CLOSED, "Already settled");
        state = ContestState.CANCELLED;
        emit ContestCancelled();
    }

    /// @return toPrimaryPool Portion of `deposit` credited to `primaryPrizePool` on add (reversed on remove)
    /// @return subsidy Portion credited to `secondaryPrimarySubsidyPerEntry[entryId]` on add
    function _splitPrimaryDeposit(uint256 deposit) internal view returns (uint256 toPrimaryPool, uint256 subsidy) {
        subsidy = (deposit * primaryDepositSecondarySubsidyBps) / BPS_DENOMINATOR;
        toPrimaryPool = deposit - subsidy;
    }

    function pushPrimaryPayouts(uint256[] calldata entryIds) external onlyOracle nonReentrant {
        require(state == ContestState.SETTLED, "Contest not settled");

        for (uint256 i = 0; i < entryIds.length; i++) {
            uint256 entryId = entryIds[i];
            address owner = entryOwner[entryId];
            require(owner != address(0), "Entry withdrawn or invalid");

            uint256 payout = primaryPrizePoolPayouts[entryId];
            if (payout == 0) {
                continue;
            }

            primaryPrizePoolPayouts[entryId] = 0;

            if (primaryPrizePool >= payout) {
                primaryPrizePool -= payout;
            } else {
                primaryPrizePool = 0;
            }

            SafeTransferLib.safeTransfer(ERC20(paymentToken), owner, payout);
            emit PrimaryPayoutClaimed(owner, entryId, payout);
        }
    }

    function pushSecondaryPayouts(address[] calldata participantAddresses, uint256 entryId)
        external
        onlyOracle
        nonReentrant
    {
        require(state == ContestState.SETTLED, "Contest not settled");
        require(secondaryMarketResolved, "Market not resolved");
        require(entryId == secondaryWinningEntry, "Not winning entry");

        require(uint256(netPosition[entryId]) > 0, "No supply");

        for (uint256 i = 0; i < participantAddresses.length; i++) {
            address participant = participantAddresses[i];
            uint256 bal = balanceOf[participant][entryId];

            if (bal > 0) {
                uint256 supplyBefore = uint256(netPosition[entryId]);
                uint256 liqNow = secondaryLiquidityPerEntry[entryId];
                uint256 payout = (supplyBefore > 0 && liqNow > 0) ? (bal * liqNow) / supplyBefore : 0;

                _burn(participant, entryId, bal);
                netPosition[entryId] -= int256(bal);

                secondaryDepositedPerEntry[participant][entryId] = 0;

                if (payout > 0) {
                    if (secondaryLiquidityPerEntry[entryId] >= payout) {
                        secondaryLiquidityPerEntry[entryId] -= payout;
                    } else {
                        secondaryLiquidityPerEntry[entryId] = 0;
                    }

                    SafeTransferLib.safeTransfer(ERC20(paymentToken), participant, payout);
                    emit SecondaryPayoutClaimed(participant, entryId, payout);
                }
            }
        }
    }

    function uri(uint256) public pure override returns (string memory) {
        return "";
    }

    function getEntriesCount() external view returns (uint256) {
        return entries.length;
    }

    function getEntryAtIndex(uint256 index) external view returns (uint256) {
        require(index < entries.length, "Invalid index");
        return entries[index];
    }

    function _removeActiveEntry(uint256 entryId) internal {
        uint256 idxPlusOne = entryIndexPlusOne[entryId];
        require(idxPlusOne != 0, "Entry not active");

        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = entries.length - 1;

        if (idx != lastIdx) {
            uint256 movedEntryId = entries[lastIdx];
            entries[idx] = movedEntryId;
            entryIndexPlusOne[movedEntryId] = idx + 1;
        }

        entries.pop();
        entryIndexPlusOne[entryId] = 0;
    }

    /// @notice Sum of backed (`secondaryLiquidityPerEntry`) plus primary subsidy per active entry
    function totalSecondaryLiquidity() public view returns (uint256 sum) {
        for (uint256 i = 0; i < entries.length; i++) {
            uint256 eid = entries[i];
            sum += secondaryLiquidityPerEntry[eid] + secondaryPrimarySubsidyPerEntry[eid];
        }
    }

    function getPrimarySideBalance() external view returns (uint256) {
        return primaryPrizePool;
    }

    function getSecondarySideBalance() external view returns (uint256) {
        return totalSecondaryLiquidity();
    }

    /// @notice Marginal bonding-curve price for `entryId` from current net ERC1155 supply
    function calculateSecondaryPrice(uint256 entryId) external view returns (uint256) {
        int256 np = netPosition[entryId];
        uint256 shares = np > 0 ? uint256(np) : 0;
        return SecondaryPricing.calculatePrice(shares);
    }
}
