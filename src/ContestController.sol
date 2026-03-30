// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "solmate/tokens/ERC1155.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "solmate/utils/SafeTransferLib.sol";
import "./PrimaryContest.sol";
import "./SecondaryContest.sol";
import "./SecondaryPricing.sol";

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title ContestController
 * @dev Layer 1: primary prize pool only. Layer 2: per-entry bonding curve + secondaryLiquidityPerEntry.
 *      primaryEntryInvestmentShareBps of each secondary buy mints to entry owner first, then buyer.
 */
contract ContestController is ERC1155, ReentrancyGuard {
    address public immutable paymentToken;
    address public immutable oracle;
    uint256 public immutable primaryDepositAmount;
    uint256 public immutable oracleFeeBps;
    uint256 public immutable expiryTimestamp;

    /// @notice BPS of each secondary payment used for primary entry owner curve leg (before buyer leg)
    uint256 public immutable primaryEntryInvestmentShareBps;

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
    uint256 public accumulatedOracleFee;

    uint256[] public entries;
    mapping(uint256 => address) public entryOwner;
    uint256 public primaryPrizePool;
    mapping(uint256 => uint256) public primaryPrizePoolPayouts;
    bytes32 public primaryMerkleRoot;

    mapping(uint256 => int256) public netPosition;
    /// @notice Payment token backing this entry's secondary ERC1155 (buy adds; sell/settle removes pro-rata)
    mapping(uint256 => uint256) public secondaryLiquidityPerEntry;

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
        uint256 participantTokensReceived,
        uint256 primaryEntryInvestment,
        uint256 ownerTokensReceived
    );
    event SecondaryPositionSold(address indexed participant, uint256 indexed entryId, uint256 tokenAmount, uint256 proceeds);
    event SecondaryPayoutClaimed(address indexed participant, uint256 indexed entryId, uint256 payout);
    event SecondaryMerkleRootUpdated(bytes32 newRoot);

    event ContestActivated();
    event ContestLocked();
    event ContestSettled(uint256[] winningEntries, uint256[] payouts);
    event ContestCancelled();
    event ContestClosed();

    modifier onlyOracle() {
        require(msg.sender == oracle, "Not oracle");
        _;
    }

    constructor(
        address _paymentToken,
        address _oracle,
        uint256 _primaryDepositAmount,
        uint256 _oracleFeeBps,
        uint256 _expiryTimestamp,
        uint256 _primaryEntryInvestmentShareBps
    ) ERC1155() {
        require(_paymentToken != address(0), "Invalid payment token");
        require(_oracle != address(0), "Invalid oracle");
        require(_primaryDepositAmount > 0, "Invalid deposit amount");
        require(_oracleFeeBps <= 1000, "Oracle fee too high");
        require(_expiryTimestamp > block.timestamp, "Expiry in past");
        require(_primaryEntryInvestmentShareBps <= BPS_DENOMINATOR, "Invalid primary entry investment share");

        paymentToken = _paymentToken;
        oracle = _oracle;
        primaryDepositAmount = _primaryDepositAmount;
        oracleFeeBps = _oracleFeeBps;
        expiryTimestamp = _expiryTimestamp;
        primaryEntryInvestmentShareBps = _primaryEntryInvestmentShareBps;

        state = ContestState.OPEN;
    }

    function addPrimaryPosition(uint256 entryId, bytes32[] calldata merkleProof) external nonReentrant {
        PrimaryContest.validatePrimaryMerkleProof(primaryMerkleRoot, msg.sender, merkleProof);
        PrimaryContest.validateAddPrimaryPosition(entryOwner, entryId, expiryTimestamp, uint8(state));

        PrimaryContest.processAddPrimaryPosition(entries, entryOwner, entryId, msg.sender, primaryDepositAmount);

        primaryPrizePool += primaryDepositAmount;

        SafeTransferLib.safeTransferFrom(ERC20(paymentToken), msg.sender, address(this), primaryDepositAmount);
    }

    function removePrimaryPosition(uint256 entryId) external nonReentrant {
        PrimaryContest.validateRemovePrimaryPosition(entryOwner, entryId, msg.sender, uint8(state));

        (uint256 refundAmount, uint256 primaryContribution) =
            PrimaryContest.processRemovePrimaryPosition(entryOwner, entryId, primaryDepositAmount);

        primaryPrizePool -= primaryContribution;

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

        uint256 oracleFee = _calculateOracleFee(payout);
        uint256 netClaim = payout - oracleFee;
        if (oracleFee > 0) {
            accumulatedOracleFee += oracleFee;
        }

        SafeTransferLib.safeTransfer(ERC20(paymentToken), msg.sender, netClaim);
        emit PrimaryPayoutClaimed(msg.sender, entryId, netClaim);
    }

    function addSecondaryPosition(uint256 entryId, uint256 amount, bytes32[] calldata merkleProof)
        external
        nonReentrant
    {
        SecondaryContest.validateSecondaryMerkleProof(secondaryMerkleRoot, msg.sender, merkleProof);
        SecondaryContest.validateAddSecondaryPosition(entryOwner, entryId, amount, uint8(state));

        uint256 investmentAmount = (amount * primaryEntryInvestmentShareBps) / BPS_DENOMINATOR;
        uint256 remainingAmount = amount - investmentAmount;

        int256 netPos = netPosition[entryId];
        uint256 shares0 = netPos > 0 ? uint256(netPos) : 0;

        uint256 ownerTokens = investmentAmount > 0
            ? SecondaryPricing.calculateTokensFromCollateral(shares0, investmentAmount)
            : 0;
        if (investmentAmount > 0) {
            require(ownerTokens > 0, "Payment too small: primary entry investment buys no tokens");
        }

        uint256 shares1 = shares0 + ownerTokens;
        uint256 buyerTokens = SecondaryPricing.calculateTokensFromCollateral(shares1, remainingAmount);
        require(buyerTokens > 0, "Payment too small: insufficient to purchase tokens");

        secondaryLiquidityPerEntry[entryId] += amount;

        SecondaryContest.processAddSecondaryPosition(
            netPosition,
            entryId,
            msg.sender,
            amount,
            investmentAmount,
            ownerTokens,
            buyerTokens
        );

        address owner = entryOwner[entryId];
        if (ownerTokens > 0) {
            _mint(owner, entryId, ownerTokens, "");
        }
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

        if (payout > 0) {
            if (secondaryLiquidityPerEntry[entryId] >= payout) {
                secondaryLiquidityPerEntry[entryId] -= payout;
            } else {
                secondaryLiquidityPerEntry[entryId] = 0;
            }

            uint256 oracleFee = _calculateOracleFee(payout);
            uint256 netPayout = payout - oracleFee;
            if (oracleFee > 0) {
                accumulatedOracleFee += oracleFee;
            }
            SafeTransferLib.safeTransfer(ERC20(paymentToken), msg.sender, netPayout);
            emit SecondaryPayoutClaimed(msg.sender, entryId, netPayout);
        } else {
            emit SecondaryPayoutClaimed(msg.sender, entryId, 0);
        }

        if (uint256(netPosition[entryId]) == 0) {
            uint256 remaining = IERC20Balance(paymentToken).balanceOf(address(this));
            uint256 sweepable = remaining > accumulatedOracleFee ? remaining - accumulatedOracleFee : 0;
            if (sweepable > 0) {
                secondaryLiquidityPerEntry[entryId] = 0;
                SafeTransferLib.safeTransfer(ERC20(paymentToken), msg.sender, sweepable);
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

    function settleContest(uint256[] calldata winningEntries, uint256[] calldata payoutBps)
        external
        onlyOracle
        nonReentrant
    {
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

        state = ContestState.SETTLED;

        uint256 layer1Pool = primaryPrizePool;
        for (uint256 i = 0; i < winningEntries.length; i++) {
            uint256 entryId = winningEntries[i];
            uint256 payout = (layer1Pool * payoutBps[i]) / BPS_DENOMINATOR;
            primaryPrizePoolPayouts[entryId] = payout;
        }

        secondaryWinningEntry = winningEntries[0];
        secondaryMarketResolved = true;

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
            accumulatedOracleFee = 0;
            for (uint256 i = 0; i < entries.length; i++) {
                secondaryLiquidityPerEntry[entries[i]] = 0;
            }

            state = ContestState.CLOSED;
            SafeTransferLib.safeTransfer(ERC20(paymentToken), oracle, remaining);
            emit ContestClosed();
        }
    }

    function claimOracleFee() external nonReentrant {
        require(msg.sender == oracle, "Not oracle");
        require(accumulatedOracleFee > 0, "No fee to claim");

        uint256 fee = accumulatedOracleFee;
        accumulatedOracleFee = 0;
        SafeTransferLib.safeTransfer(ERC20(paymentToken), oracle, fee);
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

    function _calculateOracleFee(uint256 amount) internal view returns (uint256 fee) {
        fee = (amount * oracleFeeBps) / BPS_DENOMINATOR;
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

            uint256 oracleFee = _calculateOracleFee(payout);
            uint256 netClaim = payout - oracleFee;
            if (oracleFee > 0) {
                accumulatedOracleFee += oracleFee;
            }
            SafeTransferLib.safeTransfer(ERC20(paymentToken), owner, netClaim);
            emit PrimaryPayoutClaimed(owner, entryId, netClaim);
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

                if (payout > 0) {
                    if (secondaryLiquidityPerEntry[entryId] >= payout) {
                        secondaryLiquidityPerEntry[entryId] -= payout;
                    } else {
                        secondaryLiquidityPerEntry[entryId] = 0;
                    }

                    uint256 oracleFee = _calculateOracleFee(payout);
                    uint256 netPayout = payout - oracleFee;
                    if (oracleFee > 0) {
                        accumulatedOracleFee += oracleFee;
                    }
                    SafeTransferLib.safeTransfer(ERC20(paymentToken), participant, netPayout);
                    emit SecondaryPayoutClaimed(participant, entryId, netPayout);
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

    /// @notice Sum of secondaryLiquidityPerEntry over all primary entries
    function totalSecondaryLiquidity() public view returns (uint256 sum) {
        for (uint256 i = 0; i < entries.length; i++) {
            sum += secondaryLiquidityPerEntry[entries[i]];
        }
    }

    function getPrimarySideBalance() external view returns (uint256) {
        return primaryPrizePool;
    }

    function getSecondarySideBalance() external view returns (uint256) {
        return totalSecondaryLiquidity();
    }

    function getPrimarySideShareBps() external view returns (uint256) {
        uint256 p = primaryPrizePool;
        uint256 s = totalSecondaryLiquidity();
        uint256 t = p + s;
        if (t == 0) {
            return 0;
        }
        return (p * BPS_DENOMINATOR) / t;
    }

    /// @notice Marginal bonding-curve price for `entryId` from current net ERC1155 supply
    function calculateSecondaryPrice(uint256 entryId) external view returns (uint256) {
        int256 np = netPosition[entryId];
        uint256 shares = np > 0 ? uint256(np) : 0;
        return SecondaryPricing.calculatePrice(shares);
    }
}
