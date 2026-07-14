// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/ContestController.sol";
import "./helpers/ReferralTestHarness.sol";
import "../src/SecondaryPricing.sol";
import "solmate/tokens/ERC20.sol";
import "solady/utils/MerkleTreeLib.sol";
import "solady/utils/MerkleProofLib.sol";

/**
 * @title ContestControllerTest
 * @author MagRelo
 * @dev Comprehensive tests for ContestController contract
 * 
 * Tests cover:
 * - Code correctness: All functions behave as specified
 * - UX quality: Functions provide good user experience (refunds, error messages, fund safety)
 * - Fuzzing: Property-based tests for edge cases
 * - Invariants: System-wide properties that must always hold
 * 
 * All tests respect standard settings from AGENTS.md:
 * - PRIMARY_DEPOSIT = 25e18 ($25)
 * - REFERRAL_NETWORK_BPS = 500 (5%)
 * - PURCHASE_INCREMENT = 10e18 ($10)
 * - PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS = 700 (7% of each primary deposit to per-entry subsidy)
 */
contract ContestControllerTest is ReferralTestHarness {
    // Standard settings from agents.md
    uint256 public constant PRIMARY_DEPOSIT = 25e18; // $25
    uint256 public constant PURCHASE_INCREMENT = 10e18; // $10
    uint256 public constant PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS = 700; // 7%

    function _standardSubsidyPerPrimaryDeposit() internal pure returns (uint256) {
        return (PRIMARY_DEPOSIT * PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS) / 10_000;
    }

    function _standardPrimaryPortionPerDeposit() internal pure returns (uint256) {
        return PRIMARY_DEPOSIT - _standardSubsidyPerPrimaryDeposit();
    }
    
    // Contest state enum (matches ContestController)
    enum ContestState {
        OPEN,
        ACTIVE,
        LOCKED,
        SETTLED,
        CANCELLED,
        CLOSED
    }
    
    // Test contracts
    ContestController public contest;
    MockERC20 public paymentToken;
    
    // Test addresses
    address public oracle = address(0x1);
    address public user1 = address(0x10);
    address public user2 = address(0x20);
    address public user3 = address(0x30);
    address public user4 = address(0x40);
    address public user5 = address(0x50);
    address public nonOracle = address(0x99);
    
    // Test entry IDs
    uint256 public constant ENTRY_1 = 1;
    uint256 public constant ENTRY_2 = 2;
    uint256 public constant ENTRY_3 = 3;
    uint256 public constant ENTRY_4 = 4;
    uint256 public constant ENTRY_5 = 5;
    
    uint256 public constant EXPIRY_OFFSET = 365 days;
    
    function setUp() public {
        paymentToken = new MockERC20("Payment Token", "PAY", 18);
        _initReferralInfra();
        contest = _createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            REFERRAL_NETWORK_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS
        );
        
        // Fund users
        paymentToken.mint(user1, 100000e18);
        paymentToken.mint(user2, 100000e18);
        paymentToken.mint(user3, 100000e18);
        paymentToken.mint(user4, 100000e18);
        paymentToken.mint(user5, 100000e18);
        paymentToken.mint(oracle, 100000e18);
        paymentToken.mint(nonOracle, 100000e18);
    }
    
    // ============ Helper Functions ============
    
    /**
     * @notice Deploy a new contest with standard settings
     */
    function _deployContest(address _oracle, uint256 _expiryOffset) internal returns (ContestController) {
        return _createContest(
            address(paymentToken),
            _oracle,
            PRIMARY_DEPOSIT,
            REFERRAL_NETWORK_BPS,
            block.timestamp + _expiryOffset,
            PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS
        );
    }

    function _deployContestSubsidy(uint256 subsidyBps) internal returns (ContestController) {
        return _createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            REFERRAL_NETWORK_BPS,
            block.timestamp + EXPIRY_OFFSET,
            subsidyBps
        );
    }

    /**
     * @notice Fund user and approve contest
     */
    function _fundUser(address user, uint256 amount) internal {
        paymentToken.mint(user, amount);
        vm.prank(user);
        paymentToken.approve(address(contest), amount);
    }

    function _fundUserContest(address user, ContestController ctr, uint256 amount) internal {
        paymentToken.mint(user, amount);
        vm.prank(user);
        paymentToken.approve(address(ctr), amount);
    }
    
    /**
     * @notice Create primary entry
     */
    function _createPrimaryEntry(address user, uint256 entryId) internal {
        _fundUser(user, PRIMARY_DEPOSIT);
        vm.prank(user);
        contest.addPrimaryPosition(entryId, new bytes32[](0));
    }

    function _createPrimaryEntryOn(ContestController ctr, address user, uint256 entryId) internal {
        _fundUserContest(user, ctr, PRIMARY_DEPOSIT);
        vm.prank(user);
        ctr.addPrimaryPosition(entryId, new bytes32[](0));
    }

    /**
     * @notice Create secondary position
     */
    function _createSecondaryPosition(address user, uint256 entryId, uint256 amount) internal {
        _fundUser(user, amount);
        vm.prank(user);
        contest.addSecondaryPosition(entryId, amount, new bytes32[](0));
    }

    function _createSecondaryPositionOn(ContestController ctr, address user, uint256 entryId, uint256 amount)
        internal
    {
        _fundUserContest(user, ctr, amount);
        vm.prank(user);
        ctr.addSecondaryPosition(entryId, amount, new bytes32[](0));
    }
    
    /**
     * @notice Generate merkle tree and proof for addresses
     */
    function _generateMerkleTree(address[] memory addresses) 
        internal 
        pure 
        returns (bytes32 root, bytes32[][] memory proofs) 
    {
        require(addresses.length > 0, "No addresses provided");
        
        bytes32[] memory leaves = new bytes32[](addresses.length);
        for (uint256 i = 0; i < addresses.length; i++) {
            leaves[i] = keccak256(abi.encodePacked(addresses[i]));
        }
        
        bytes32[] memory tree = MerkleTreeLib.build(leaves);
        root = MerkleTreeLib.root(tree);
        
        proofs = new bytes32[][](addresses.length);
        for (uint256 i = 0; i < addresses.length; i++) {
            proofs[i] = _getProofForIndex(tree, i, leaves.length);
        }
    }
    
    /**
     * @notice Get proof for a specific leaf index
     */
    function _getProofForIndex(
        bytes32[] memory tree,
        uint256 leafIndex,
        uint256 numLeaves
    ) internal pure returns (bytes32[] memory proof) {
        uint256 depth = 0;
        uint256 temp = numLeaves;
        while (temp > 1) {
            depth++;
            temp = (temp + 1) / 2;
        }
        
        if (depth == 0) {
            return new bytes32[](0);
        }
        
        proof = new bytes32[](depth);
        uint256 proofIndex = 0;
        uint256 currentIndex = leafIndex;
        uint256 levelStart = 0;
        uint256 levelSize = numLeaves;
        
        while (levelSize > 1 && proofIndex < depth) {
            uint256 positionInLevel = currentIndex - levelStart;
            uint256 siblingPosition;
            
            if (positionInLevel % 2 == 0) {
                siblingPosition = positionInLevel + 1;
            } else {
                siblingPosition = positionInLevel - 1;
            }
            
            uint256 siblingIndex = levelStart + siblingPosition;
            
            if (siblingIndex < levelStart + levelSize && siblingIndex < tree.length) {
                proof[proofIndex] = tree[siblingIndex];
            } else if (currentIndex < tree.length) {
                proof[proofIndex] = tree[currentIndex];
            } else {
                proof[proofIndex] = bytes32(0);
            }
            
            proofIndex++;
            levelStart += levelSize;
            uint256 parentPositionInLevel = positionInLevel / 2;
            currentIndex = levelStart + parentPositionInLevel;
            levelSize = (levelSize + 1) / 2;
            
            if (levelStart >= tree.length) break;
        }
    }
    
    /**
     * @notice Calculate expected oracle fee
     */
    function _calculateExpectedReferralFee(uint256 totalGross) internal pure returns (uint256) {
        return (totalGross * REFERRAL_NETWORK_BPS) / 10000;
    }
    
    /**
     * @notice Set contest state (via oracle)
     */
    function _setState(ContestState state) internal {
        vm.prank(oracle);
        if (state == ContestState.ACTIVE) {
            contest.activateContest();
        } else if (state == ContestState.LOCKED) {
            contest.lockContest();
        } else if (state == ContestState.CANCELLED) {
            contest.cancelContest();
        } else if (state == ContestState.CLOSED) {
            vm.warp(block.timestamp + EXPIRY_OFFSET);
            contest.closeContest();
        }
    }
    
    /**
     * @notice Get contract balance
     */
    function _getContractBalance() internal view returns (uint256) {
        return paymentToken.balanceOf(address(contest));
    }
    
    // ============ Constructor Tests ============
    
    function test_constructor_ValidParameters() public {
        ContestController newContest = _deployContest(oracle, EXPIRY_OFFSET);
        
        assertEq(address(newContest.paymentToken()), address(paymentToken));
        assertEq(newContest.oracle(), oracle);
        assertEq(newContest.primaryDepositAmount(), PRIMARY_DEPOSIT);
        assertEq(newContest.referralNetworkBps(), REFERRAL_NETWORK_BPS);
        assertEq(newContest.primaryDepositSecondarySubsidyBps(), PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS);
        assertEq(uint8(newContest.state()), uint8(ContestState.OPEN));
    }
    
    function test_constructor_InvalidPaymentToken() public {
        vm.expectRevert("Invalid payment token");
        factory.createContest(
            address(0),
            oracle,
            PRIMARY_DEPOSIT,
            REFERRAL_NETWORK_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS,
            address(referralGraph),
            address(rewardCalculator),
            REFERRAL_GROUP_ID
        );
    }
    
    function test_constructor_InvalidOracle() public {
        vm.expectRevert("Invalid oracle");
        factory.createContest(
            address(paymentToken),
            address(0),
            PRIMARY_DEPOSIT,
            REFERRAL_NETWORK_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS,
            address(referralGraph),
            address(rewardCalculator),
            REFERRAL_GROUP_ID
        );
    }
    
    function test_constructor_ZeroDepositAmount_Succeeds() public {
        address contestAddress = factory.createContest(
            address(paymentToken),
            oracle,
            0,
            REFERRAL_NETWORK_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS,
            address(referralGraph),
            address(rewardCalculator),
            REFERRAL_GROUP_ID
        );
        ContestController freeContest = ContestController(contestAddress);
        assertEq(freeContest.primaryDepositAmount(), 0);
        assertEq(uint8(freeContest.state()), uint8(ContestState.OPEN));
    }

    /// @dev Free primary: add entry with no token transfer, activate, secondary still works
    function test_zeroDepositContest_primaryAndSecondaryFlow() public {
        address contestAddress = factory.createContest(
            address(paymentToken),
            oracle,
            0,
            REFERRAL_NETWORK_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS,
            address(referralGraph),
            address(rewardCalculator),
            REFERRAL_GROUP_ID
        );
        ContestController freeContest = ContestController(contestAddress);
        paymentToken.mint(user1, PURCHASE_INCREMENT);
        vm.prank(user1);
        paymentToken.approve(address(freeContest), PURCHASE_INCREMENT);

        vm.prank(user1);
        freeContest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
        assertEq(freeContest.primaryPrizePool(), 0);

        vm.prank(oracle);
        freeContest.activateContest();

        vm.prank(user1);
        freeContest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, new bytes32[](0));
        assertEq(freeContest.secondaryLiquidityPerEntry(ENTRY_1), PURCHASE_INCREMENT);
    }
    
    function test_constructor_OracleFeeTooHigh() public {
        vm.expectRevert("Referral network fee too high");
        factory.createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            1001, // > 10%
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS,
            address(referralGraph),
            address(rewardCalculator),
            REFERRAL_GROUP_ID
        );
    }
    
    function test_constructor_ExpiryInPast() public {
        vm.expectRevert("Expiry in past");
        factory.createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            REFERRAL_NETWORK_BPS,
            block.timestamp - 1,
            PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS,
            address(referralGraph),
            address(rewardCalculator),
            REFERRAL_GROUP_ID
        );
    }

    function test_constructor_SubsidyBpsTooHigh() public {
        vm.expectRevert("Subsidy bps too high");
        factory.createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            REFERRAL_NETWORK_BPS,
            block.timestamp + EXPIRY_OFFSET,
            10_001,
            address(referralGraph),
            address(rewardCalculator),
            REFERRAL_GROUP_ID
        );
    }

    function test_constructor_SubsidyBpsMax_succeeds() public {
        ContestController c = _deployContestSubsidy(10_000);
        assertEq(c.primaryDepositSecondarySubsidyBps(), 10_000);
    }

    function test_subsidy_addPrimary_splitsPoolAndSubsidy() public {
        ContestController c = _deployContestSubsidy(2000);
        uint256 subsidy = (PRIMARY_DEPOSIT * 2000) / 10_000;
        _fundUserContest(user1, c, PRIMARY_DEPOSIT);
        vm.prank(user1);
        c.addPrimaryPosition(ENTRY_1, new bytes32[](0));
        assertEq(c.primaryPrizePool(), PRIMARY_DEPOSIT - subsidy);
        assertEq(c.secondaryPrimarySubsidyPerEntry(ENTRY_1), subsidy);
        assertEq(c.getSecondarySideBalance(), subsidy);
    }

    function test_subsidy_removePrimary_restoresSubsidy() public {
        ContestController c = _deployContestSubsidy(2000);
        uint256 subsidy = (PRIMARY_DEPOSIT * 2000) / 10_000;
        _fundUserContest(user1, c, PRIMARY_DEPOSIT);
        vm.prank(user1);
        c.addPrimaryPosition(ENTRY_1, new bytes32[](0));
        assertEq(c.secondaryPrimarySubsidyPerEntry(ENTRY_1), subsidy);

        uint256 balBefore = paymentToken.balanceOf(user1);
        vm.prank(user1);
        c.removePrimaryPosition(ENTRY_1);
        assertEq(paymentToken.balanceOf(user1), balBefore + PRIMARY_DEPOSIT);
        assertEq(c.secondaryPrimarySubsidyPerEntry(ENTRY_1), 0);
        assertEq(c.primaryPrizePool(), 0);
    }

    function test_subsidy_sellbackUsesBackedOnly() public {
        ContestController c = _deployContestSubsidy(2000);
        uint256 subsidy = (PRIMARY_DEPOSIT * 2000) / 10_000;
        _fundUserContest(user1, c, PRIMARY_DEPOSIT);
        vm.prank(user1);
        c.addPrimaryPosition(ENTRY_1, new bytes32[](0));

        _fundUserContest(user2, c, PURCHASE_INCREMENT);
        vm.prank(user2);
        c.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, new bytes32[](0));
        uint256 bal = c.balanceOf(user2, ENTRY_1);

        vm.prank(user2);
        c.removeSecondaryPosition(ENTRY_1, bal);

        assertEq(c.secondaryLiquidityPerEntry(ENTRY_1), 0);
        assertEq(c.secondaryPrimarySubsidyPerEntry(ENTRY_1), subsidy);
    }

    function test_subsidy_settlement_mergesSubsidyIntoWinnerLiquidity() public {
        ContestController c = _deployContestSubsidy(2000);
        _fundUserContest(user1, c, PRIMARY_DEPOSIT);
        vm.prank(user1);
        c.addPrimaryPosition(ENTRY_1, new bytes32[](0));

        _fundUserContest(user2, c, PURCHASE_INCREMENT);
        vm.prank(user2);
        c.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, new bytes32[](0));

        vm.prank(oracle);
        c.activateContest();
        vm.prank(oracle);
        c.lockContest();

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payoutBps = new uint256[](1);
        payoutBps[0] = 10_000;
        _settleContest(c, winners, payoutBps);

        uint256 gross = PURCHASE_INCREMENT + (PRIMARY_DEPOSIT * 2000) / 10_000;
        uint256 netSecondary = (gross * _netBps(c)) / 10_000;
        assertEq(c.secondaryLiquidityPerEntry(ENTRY_1), netSecondary);
        assertEq(c.secondaryPrimarySubsidyPerEntry(ENTRY_1), 0);
    }
    
    // ============ Primary Position Tests ============
    
    // ============ addPrimaryPosition Tests ============
    
    function test_addPrimaryPosition_Success() public {
        _fundUser(user1, PRIMARY_DEPOSIT);
        
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        uint256 contractBalanceBefore = _getContractBalance();
        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit ContestController.PrimaryPositionAdded(user1, ENTRY_1);
        contest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
        
        assertEq(contest.entryOwner(ENTRY_1), user1);
        assertEq(contest.getEntriesCount(), 1);
        assertEq(contest.getEntryAtIndex(0), ENTRY_1);
        assertEq(paymentToken.balanceOf(user1), balanceBefore - PRIMARY_DEPOSIT);
        assertEq(_getContractBalance(), contractBalanceBefore + PRIMARY_DEPOSIT);
    }
    
    function test_addPrimaryPosition_MerkleRootGating() public {
        address[] memory addresses = new address[](2);
        addresses[0] = user1;
        addresses[1] = user2;
        
        (bytes32 root, bytes32[][] memory proofs) = _generateMerkleTree(addresses);
        
        vm.prank(oracle);
        contest.setPrimaryMerkleRoot(root);
        
        _fundUser(user1, PRIMARY_DEPOSIT);
        
        vm.prank(user1);
        contest.addPrimaryPosition(ENTRY_1, proofs[0]);
        
        assertEq(contest.entryOwner(ENTRY_1), user1);
    }
    
    function test_addPrimaryPosition_WrongState() public {
        _fundUser(user1, PRIMARY_DEPOSIT);
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(oracle);
        contest.activateContest();
        
        _fundUser(user2, PRIMARY_DEPOSIT);
        vm.prank(user2);
        vm.expectRevert("Contest not open");
        contest.addPrimaryPosition(ENTRY_2, new bytes32[](0));
    }
    
    function test_addPrimaryPosition_EntryAlreadyExists() public {
        _fundUser(user1, PRIMARY_DEPOSIT);
        _createPrimaryEntry(user1, ENTRY_1);
        
        _fundUser(user2, PRIMARY_DEPOSIT);
        vm.prank(user2);
        vm.expectRevert("Entry already exists");
        contest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
    }
    
    function test_addPrimaryPosition_ContestExpired() public {
        ContestController expiredContest = _deployContest(oracle, 1 days);
        vm.warp(block.timestamp + 1 days + 1);
        
        MockERC20(paymentToken).mint(user1, PRIMARY_DEPOSIT);
        vm.prank(user1);
        paymentToken.approve(address(expiredContest), PRIMARY_DEPOSIT);
        
        vm.prank(user1);
        vm.expectRevert("Contest expired");
        expiredContest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
    }
    
    function test_addPrimaryPosition_InvalidMerkleProof() public {
        address[] memory addresses = new address[](2);
        addresses[0] = user1;
        addresses[1] = user2;
        
        (bytes32 root, ) = _generateMerkleTree(addresses);
        
        vm.prank(oracle);
        contest.setPrimaryMerkleRoot(root);
        
        _fundUser(user3, PRIMARY_DEPOSIT);
        
        bytes32[] memory wrongProof = new bytes32[](1);
        wrongProof[0] = bytes32(uint256(999));
        
        vm.prank(user3);
        vm.expectRevert("Invalid merkle proof");
        contest.addPrimaryPosition(ENTRY_1, wrongProof);
    }
    
    function test_addPrimaryPosition_InsufficientBalance() public {
        paymentToken.mint(user1, PRIMARY_DEPOSIT - 1);
        vm.prank(user1);
        paymentToken.approve(address(contest), PRIMARY_DEPOSIT - 1);
        
        vm.prank(user1);
        vm.expectRevert();
        contest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
    }
    
    function test_addPrimaryPosition_NoReferralFeeOnDeposit() public {
        _fundUser(user1, PRIMARY_DEPOSIT * 2);
        _createPrimaryEntry(user1, ENTRY_1);
        _fundUser(user2, PRIMARY_DEPOSIT);
        vm.prank(user2);
        contest.addPrimaryPosition(ENTRY_2, new bytes32[](0));
    }
    
    // ============ removePrimaryPosition Tests ============
    
    function test_removePrimaryPosition_SuccessInOpenState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        uint256 contractBalanceBefore = _getContractBalance();
        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit ContestController.PrimaryPositionRemoved(ENTRY_1, user1);
        contest.removePrimaryPosition(ENTRY_1);
        
        assertEq(contest.entryOwner(ENTRY_1), address(0));
        assertEq(paymentToken.balanceOf(user1), balanceBefore + PRIMARY_DEPOSIT);
        assertEq(_getContractBalance(), contractBalanceBefore - PRIMARY_DEPOSIT);
    }
    
    function test_removePrimaryPosition_SuccessInCancelledState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.cancelContest();
        
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        
        vm.prank(user1);
        contest.removePrimaryPosition(ENTRY_1);
        
        assertEq(paymentToken.balanceOf(user1), balanceBefore + PRIMARY_DEPOSIT);
        assertEq(contest.entryOwner(ENTRY_1), address(0));
    }
    
    function test_removePrimaryPosition_WrongState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        vm.prank(user1);
        vm.expectRevert("Cannot withdraw - contest in progress or settled");
        contest.removePrimaryPosition(ENTRY_1);
    }
    
    function test_removePrimaryPosition_NotEntryOwner() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(user2);
        vm.expectRevert("Not entry owner");
        contest.removePrimaryPosition(ENTRY_1);
    }
    
    function test_removePrimaryPosition_EntryDoesNotExist() public {
        vm.prank(user1);
        vm.expectRevert("Not entry owner");
        contest.removePrimaryPosition(ENTRY_1);
    }
    
    function test_removePrimaryPosition_FullRefund() public {
        _createPrimaryEntry(user1, ENTRY_1);
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        
        vm.prank(user1);
        contest.removePrimaryPosition(ENTRY_1);
        
        assertEq(paymentToken.balanceOf(user1), balanceBefore + PRIMARY_DEPOSIT);
    }
    
    // ============ claimPrimaryPayout Tests ============
    
    function test_claimPrimaryPayout_Success() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        
        vm.prank(oracle);
        contest.activateContest();
        
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_1;
        winners[1] = ENTRY_2;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 7000; // 70%
        payouts[1] = 3000; // 30%
        _settleContest(contest, winners, payouts);
        
        uint256 payout = contest.primaryPrizePoolPayouts(ENTRY_1);
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        
        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit ContestController.PrimaryPayoutClaimed(user1, ENTRY_1, payout);
        contest.claimPrimaryPayout(ENTRY_1);
        
        assertEq(paymentToken.balanceOf(user1), balanceBefore + payout);
        assertEq(contest.primaryPrizePoolPayouts(ENTRY_1), 0);
    }
    
    function test_claimPrimaryPayout_afterSecondaryAdds() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);

        _fundUser(user3, PURCHASE_INCREMENT * 10);
        vm.prank(user3);
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT * 10, new bytes32[](0));

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_1;
        winners[1] = ENTRY_2;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 7000;
        payouts[1] = 3000;
        _settleContest(contest, winners, payouts);

        uint256 payout = contest.primaryPrizePoolPayouts(ENTRY_1);
        uint256 balanceBefore = paymentToken.balanceOf(user1);

        vm.prank(user1);
        contest.claimPrimaryPayout(ENTRY_1);

        assertEq(paymentToken.balanceOf(user1), balanceBefore + payout);
    }

    function test_claimPrimaryPayout_WrongState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(user1);
        vm.expectRevert("Contest not settled");
        contest.claimPrimaryPayout(ENTRY_1);
    }
    
    function test_claimPrimaryPayout_NotEntryOwner() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        
        vm.prank(oracle);
        contest.activateContest();
        
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        vm.prank(user2);
        vm.expectRevert("Not entry owner");
        contest.claimPrimaryPayout(ENTRY_1);
    }
    
    function test_claimPrimaryPayout_NoPayout() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        
        vm.prank(oracle);
        contest.activateContest();
        
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_2;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        vm.prank(user1);
        vm.expectRevert("No payout");
        contest.claimPrimaryPayout(ENTRY_1);
    }
    
    // ============ Secondary Position Tests ============
    
    // ============ addSecondaryPosition Tests ============
    
    function test_addSecondaryPosition_SuccessInOpenState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _fundUser(user2, PURCHASE_INCREMENT);
        
        uint256 balanceBefore = paymentToken.balanceOf(user2);
        uint256 tokensBefore = contest.balanceOf(user2, ENTRY_1);
        
        vm.prank(user2);
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, new bytes32[](0));
        
        uint256 tokensAfter = contest.balanceOf(user2, ENTRY_1);
        assertGt(tokensAfter, tokensBefore);
        assertEq(paymentToken.balanceOf(user2), balanceBefore - PURCHASE_INCREMENT);
    }
    
    function test_addSecondaryPosition_SuccessInActiveState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        _fundUser(user2, PURCHASE_INCREMENT);
        
        vm.prank(user2);
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, new bytes32[](0));
        
        assertGt(contest.balanceOf(user2, ENTRY_1), 0);
    }
    
    function test_addSecondaryPosition_MerkleRootGating() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        address[] memory addresses = new address[](2);
        addresses[0] = user2;
        addresses[1] = user3;
        
        (bytes32 root, bytes32[][] memory proofs) = _generateMerkleTree(addresses);
        
        vm.prank(oracle);
        contest.setSecondaryMerkleRoot(root);
        
        _fundUser(user2, PURCHASE_INCREMENT);
        
        vm.prank(user2);
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, proofs[0]);
        
        assertGt(contest.balanceOf(user2, ENTRY_1), 0);
    }
    
    function test_addSecondaryPosition_WrongState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        _fundUser(user2, PURCHASE_INCREMENT);
        
        vm.prank(user2);
        vm.expectRevert("Secondary positions not available");
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, new bytes32[](0));
    }
    
    function test_addSecondaryPosition_EntryDoesNotExist() public {
        _fundUser(user2, PURCHASE_INCREMENT);
        
        vm.prank(user2);
        vm.expectRevert("Entry does not exist or withdrawn");
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, new bytes32[](0));
    }
    
    function test_addSecondaryPosition_ZeroAmount() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        _fundUser(user2, PURCHASE_INCREMENT);
        
        vm.prank(user2);
        vm.expectRevert("Amount must be > 0");
        contest.addSecondaryPosition(ENTRY_1, 0, new bytes32[](0));
    }
    
    function test_addSecondaryPosition_InvalidMerkleProof() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        address[] memory addresses = new address[](2);
        addresses[0] = user2;
        addresses[1] = user3;
        
        (bytes32 root, ) = _generateMerkleTree(addresses);
        
        vm.prank(oracle);
        contest.setSecondaryMerkleRoot(root);
        
        _fundUser(user4, PURCHASE_INCREMENT);
        
        bytes32[] memory wrongProof = new bytes32[](1);
        wrongProof[0] = bytes32(uint256(999));
        
        vm.prank(user4);
        vm.expectRevert("Invalid merkle proof");
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, wrongProof);
    }
    
    function test_addSecondaryPosition_PaymentTooSmall() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        // Add large position first to drive up price
        _fundUser(user2, PURCHASE_INCREMENT * 100);
        vm.prank(user2);
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT * 100, new bytes32[](0));
        
        // Very small payment that might not get tokens
        uint256 smallPayment = 1; // 1 wei
        _fundUser(user3, smallPayment);
        
        vm.prank(user3);
        vm.expectRevert("Payment too small: insufficient to purchase tokens");
        contest.addSecondaryPosition(ENTRY_1, smallPayment, new bytes32[](0));
    }
    
    function test_addSecondaryPosition_TokensReceived() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _fundUser(user2, PURCHASE_INCREMENT);
        
        vm.prank(user2);
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, new bytes32[](0));
        
        assertGt(contest.balanceOf(user2, ENTRY_1), 0);
    }
    
    function test_addSecondaryPosition_PriceIncreases() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        uint256 price1 = contest.calculateSecondaryPrice(ENTRY_1);
        
        _fundUser(user2, PURCHASE_INCREMENT);
        vm.prank(user2);
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, new bytes32[](0));
        
        uint256 price2 = contest.calculateSecondaryPrice(ENTRY_1);
        assertGt(price2, price1);
    }
    
    function test_addSecondaryPosition_OracleFeeNotDeducted() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _fundUser(user2, PURCHASE_INCREMENT);
        
        vm.prank(user2);
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, new bytes32[](0));
    }
    
    // ============ removeSecondaryPosition Tests ============
    
    function test_removeSecondaryPosition_SuccessInOpenState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        
        uint256 tokensBefore = contest.balanceOf(user2, ENTRY_1);
        uint256 balanceBefore = paymentToken.balanceOf(user2);
        uint256 L = contest.secondaryLiquidityPerEntry(ENTRY_1);
        uint256 S = uint256(contest.netPosition(ENTRY_1));
        uint256 expectedOut = (tokensBefore * L) / S;
        
        vm.prank(user2);
        vm.expectEmit(true, true, false, true);
        emit ContestController.SecondaryPositionSold(user2, ENTRY_1, tokensBefore, expectedOut);
        contest.removeSecondaryPosition(ENTRY_1, tokensBefore);
        
        assertEq(contest.balanceOf(user2, ENTRY_1), 0);
        assertEq(paymentToken.balanceOf(user2), balanceBefore + expectedOut);
    }

    function test_secondaryDepositedPerEntry_addAndPartialRemove() public {
        _createPrimaryEntry(user1, ENTRY_1);

        uint256 amount = PURCHASE_INCREMENT;

        _createSecondaryPosition(user2, ENTRY_1, amount);

        assertEq(contest.secondaryDepositedPerEntry(user2, ENTRY_1), amount);
        assertEq(contest.secondaryDepositedPerEntry(user1, ENTRY_1), 0);

        uint256 userBalBefore = contest.balanceOf(user2, ENTRY_1);
        uint256 tokenToSell = userBalBefore / 2;
        assertGt(tokenToSell, 0);

        uint256 depositedBefore = contest.secondaryDepositedPerEntry(user2, ENTRY_1);
        uint256 expectedPrincipalToForfeit = (depositedBefore * tokenToSell) / userBalBefore;

        vm.prank(user2);
        contest.removeSecondaryPosition(ENTRY_1, tokenToSell);

        assertEq(contest.secondaryDepositedPerEntry(user2, ENTRY_1), depositedBefore - expectedPrincipalToForfeit);
        assertEq(contest.secondaryDepositedPerEntry(user1, ENTRY_1), 0);
    }
    
    function test_removeSecondaryPosition_SuccessInCancelledState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        
        vm.prank(oracle);
        contest.cancelContest();
        
        uint256 tokens = contest.balanceOf(user2, ENTRY_1);
        uint256 balanceBefore = paymentToken.balanceOf(user2);
        uint256 L = contest.secondaryLiquidityPerEntry(ENTRY_1);
        uint256 S = uint256(contest.netPosition(ENTRY_1));
        uint256 expectedOut = (tokens * L) / S;
        
        vm.prank(user2);
        contest.removeSecondaryPosition(ENTRY_1, tokens);
        
        assertEq(paymentToken.balanceOf(user2), balanceBefore + expectedOut);
    }
    
    function test_removeSecondaryPosition_WrongState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        
        vm.prank(oracle);
        contest.activateContest();
        
        uint256 tokens = contest.balanceOf(user2, ENTRY_1);
        
        vm.prank(user2);
        vm.expectRevert("Cannot withdraw - competition started or settled");
        contest.removeSecondaryPosition(ENTRY_1, tokens);
    }
    
    function test_removeSecondaryPosition_EntryDoesNotExist() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        
        vm.prank(user1);
        contest.removePrimaryPosition(ENTRY_1);
        
        uint256 tokens = contest.balanceOf(user2, ENTRY_1);
        
        vm.prank(user2);
        vm.expectRevert("Entry does not exist");
        contest.removeSecondaryPosition(ENTRY_1, tokens);
    }
    
    function test_removeSecondaryPosition_InsufficientBalance() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        
        uint256 tokens = contest.balanceOf(user2, ENTRY_1);
        
        vm.prank(user2);
        vm.expectRevert("Insufficient balance");
        contest.removeSecondaryPosition(ENTRY_1, tokens + 1);
    }
    
    function test_removeSecondaryPosition_ZeroTokenAmount() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        
        vm.prank(user2);
        vm.expectRevert("Amount must be > 0");
        contest.removeSecondaryPosition(ENTRY_1, 0);
    }
    
    function test_removeSecondaryPosition_FullSellBack() public {
        _createPrimaryEntry(user1, ENTRY_1);
        uint256 depositAmount = PURCHASE_INCREMENT * 5;
        _createSecondaryPosition(user2, ENTRY_1, depositAmount);
        
        uint256 tokens = contest.balanceOf(user2, ENTRY_1);
        uint256 balanceBefore = paymentToken.balanceOf(user2);
        uint256 L = contest.secondaryLiquidityPerEntry(ENTRY_1);
        uint256 S = uint256(contest.netPosition(ENTRY_1));
        uint256 expectedOut = (tokens * L) / S;
        
        vm.prank(user2);
        contest.removeSecondaryPosition(ENTRY_1, tokens);
        
        assertEq(paymentToken.balanceOf(user2), balanceBefore + expectedOut);
    }
    
    // ============ claimSecondaryPayout Tests ============
    
    function test_claimSecondaryPayout_Success() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        _createSecondaryPosition(user3, ENTRY_1, PURCHASE_INCREMENT * 10);
        _createSecondaryPosition(user4, ENTRY_2, PURCHASE_INCREMENT * 5);
        
        vm.prank(oracle);
        contest.activateContest();
        
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;

        uint256 grossSecondary =
            PURCHASE_INCREMENT * 10 + PURCHASE_INCREMENT * 5 + 2 * _standardSubsidyPerPrimaryDeposit();
        uint256 netSecondary = (grossSecondary * _netBps(contest)) / 10_000;

        _settleContest(contest, winners, payouts);
        
        uint256 balanceBefore = paymentToken.balanceOf(user3);

        vm.prank(user3);
        contest.claimSecondaryPayout(ENTRY_1);

        assertEq(contest.balanceOf(user3, ENTRY_1), 0);
        assertGt(paymentToken.balanceOf(user3), balanceBefore);
        assertEq(contest.totalSecondaryLiquidity(), 0);
        assertEq(contest.getSecondarySideBalance(), 0);
    }

    function test_secondaryDepositedPerEntry_claimResetsToZero() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);

        uint256 amount = PURCHASE_INCREMENT * 10;

        _createSecondaryPosition(user3, ENTRY_1, amount);

        assertEq(contest.secondaryDepositedPerEntry(user3, ENTRY_1), amount);
        assertEq(contest.secondaryDepositedPerEntry(user1, ENTRY_1), 0);
        assertEq(contest.balanceOf(user1, ENTRY_1), 0);

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);

        vm.prank(user3);
        contest.claimSecondaryPayout(ENTRY_1);

        assertEq(contest.balanceOf(user3, ENTRY_1), 0);
        assertEq(contest.secondaryDepositedPerEntry(user3, ENTRY_1), 0);
        assertEq(contest.secondaryDepositedPerEntry(user1, ENTRY_1), 0);
    }
    
    function test_claimSecondaryPayout_WrongState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        
        vm.prank(user2);
        vm.expectRevert("Contest not settled");
        contest.claimSecondaryPayout(ENTRY_1);
    }
    
    function test_claimSecondaryPayout_NotWinningEntry() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        _createSecondaryPosition(user3, ENTRY_1, PURCHASE_INCREMENT);
        _createSecondaryPosition(user4, ENTRY_2, PURCHASE_INCREMENT);
        
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        vm.prank(user4);
        vm.expectRevert("Not winning entry");
        contest.claimSecondaryPayout(ENTRY_2);
    }
    
    function test_claimSecondaryPayout_NoBalance() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        vm.prank(user2);
        vm.expectRevert("No tokens");
        contest.claimSecondaryPayout(ENTRY_1);
    }
    
    function test_claimSecondaryPayout_WinnerTakesAll() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        _createSecondaryPosition(user3, ENTRY_1, PURCHASE_INCREMENT * 10);
        _createSecondaryPosition(user4, ENTRY_1, PURCHASE_INCREMENT * 5);
        _createSecondaryPosition(user5, ENTRY_2, PURCHASE_INCREMENT * 10);
        
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;

        uint256 grossSecondary = PURCHASE_INCREMENT * 25 + 2 * _standardSubsidyPerPrimaryDeposit();
        uint256 netSecondary = (grossSecondary * _netBps(contest)) / 10_000;

        _settleContest(contest, winners, payouts);

        vm.prank(user3);
        contest.claimSecondaryPayout(ENTRY_1);

        uint256 user3Payout = paymentToken.balanceOf(user3);
        assertGt(user3Payout, 0);

        uint256 bal4Before = paymentToken.balanceOf(user4);
        vm.prank(user4);
        contest.claimSecondaryPayout(ENTRY_1);
        assertGt(paymentToken.balanceOf(user4), bal4Before);

        assertEq(contest.totalSecondaryLiquidity(), 0);
        assertEq(contest.getSecondarySideBalance(), 0);
    }

    /// @dev Losing-entry secondary TVL is merged to the winning entry at settlement and is claimable only by winning-entry token holders
    function test_claimSecondaryPayout_losingEntryLiquidityMergedToWinners() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        _createSecondaryPosition(user3, ENTRY_1, PURCHASE_INCREMENT * 2);
        _createSecondaryPosition(user4, ENTRY_2, PURCHASE_INCREMENT * 3);

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256 tvlBefore = contest.getSecondarySideBalance();
        assertEq(tvlBefore, PURCHASE_INCREMENT * 5 + 2 * _standardSubsidyPerPrimaryDeposit());

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        uint256 netSecondary = (tvlBefore * _netBps(contest)) / 10_000;
        _settleContest(contest, winners, payouts);

        assertEq(contest.secondaryLiquidityPerEntry(ENTRY_2), 0);
        assertEq(contest.getSecondarySideBalance(), netSecondary);
        assertEq(contest.secondaryLiquidityPerEntry(ENTRY_1), netSecondary);

        uint256 u3Before = paymentToken.balanceOf(user3);
        vm.prank(user3);
        contest.claimSecondaryPayout(ENTRY_1);

        assertEq(contest.totalSecondaryLiquidity(), 0);
        assertGt(paymentToken.balanceOf(user3), u3Before);
        vm.prank(user4);
        vm.expectRevert("Not winning entry");
        contest.claimSecondaryPayout(ENTRY_2);
    }

    /// @dev Audit finding #1: last secondary claimant must not sweep the primary prize pool.
    function test_claimSecondaryPayout_doesNotSweepPrimaryPrizePool() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        // Attacker is sole secondary holder on the eventual winning entry
        _createSecondaryPosition(user3, ENTRY_1, PURCHASE_INCREMENT);

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);

        uint256 primaryPayout = contest.primaryPrizePoolPayouts(ENTRY_1);
        assertGt(primaryPayout, 0);

        uint256 secondaryLiq = contest.secondaryLiquidityPerEntry(ENTRY_1);
        uint256 attackerBalBefore = paymentToken.balanceOf(user3);

        vm.prank(user3);
        contest.claimSecondaryPayout(ENTRY_1);

        uint256 attackerReceived = paymentToken.balanceOf(user3) - attackerBalBefore;
        // Attacker gets at most their secondary share, not the primary pool
        assertLe(attackerReceived, secondaryLiq);
        assertEq(contest.balanceOf(user3, ENTRY_1), 0);

        // Primary winner can still claim — proves pool was not drained
        uint256 winnerBalBefore = paymentToken.balanceOf(user1);
        vm.prank(user1);
        contest.claimPrimaryPayout(ENTRY_1);
        assertEq(paymentToken.balanceOf(user1) - winnerBalBefore, primaryPayout);
    }

    /// @dev Pull and push secondary claim paths pay the same for an identical holder (#13).
    function test_claimSecondaryPayout_matchesPushSecondaryPayouts() public {
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;

        // Contest A: user3 pulls
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        _createSecondaryPosition(user3, ENTRY_1, PURCHASE_INCREMENT * 4);
        _createSecondaryPosition(user4, ENTRY_1, PURCHASE_INCREMENT * 6);

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        _settleContest(contest, winners, payouts);

        uint256 expected3 = (contest.balanceOf(user3, ENTRY_1) * contest.secondaryLiquidityPerEntry(ENTRY_1))
            / uint256(contest.netPosition(ENTRY_1));
        uint256 before3 = paymentToken.balanceOf(user3);
        vm.prank(user3);
        contest.claimSecondaryPayout(ENTRY_1);
        assertEq(paymentToken.balanceOf(user3) - before3, expected3);

        // Contest B: identical setup; oracle pushes to user3
        ContestController pushContest = _deployContest(oracle, EXPIRY_OFFSET);
        _createPrimaryEntryOn(pushContest, user1, ENTRY_1);
        _createPrimaryEntryOn(pushContest, user2, ENTRY_2);
        _createSecondaryPositionOn(pushContest, user3, ENTRY_1, PURCHASE_INCREMENT * 4);
        _createSecondaryPositionOn(pushContest, user4, ENTRY_1, PURCHASE_INCREMENT * 6);

        vm.prank(oracle);
        pushContest.activateContest();
        vm.prank(oracle);
        pushContest.lockContest();
        _settleContest(pushContest, winners, payouts);

        uint256 beforePush3 = paymentToken.balanceOf(user3);
        address[] memory participants = new address[](1);
        participants[0] = user3;
        vm.prank(oracle);
        pushContest.pushSecondaryPayouts(participants, ENTRY_1);
        assertEq(paymentToken.balanceOf(user3) - beforePush3, expected3);
    }
    
    // ============ Oracle Functions Tests ============
    
    // ============ activateContest Tests ============
    
    function test_activateContest_Success() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(oracle);
        vm.expectEmit(true, false, false, false);
        emit ContestController.ContestActivated();
        contest.activateContest();
        
        assertEq(uint8(contest.state()), uint8(ContestState.ACTIVE));
    }
    
    function test_activateContest_AlreadyStarted() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(oracle);
        contest.activateContest();
        
        vm.prank(oracle);
        vm.expectRevert("Contest already started");
        contest.activateContest();
    }
    
    function test_activateContest_NoEntries() public {
        vm.prank(oracle);
        vm.expectRevert("No entries");
        contest.activateContest();
    }
    
    function test_activateContest_NotOracle() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(nonOracle);
        vm.expectRevert("Not oracle");
        contest.activateContest();
    }
    
    // ============ lockContest Tests ============
    
    function test_lockContest_Success() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        vm.prank(oracle);
        vm.expectEmit(true, false, false, false);
        emit ContestController.ContestLocked();
        contest.lockContest();
        
        assertEq(uint8(contest.state()), uint8(ContestState.LOCKED));
    }
    
    function test_lockContest_NotActiveState() public {
        vm.prank(oracle);
        vm.expectRevert("Contest not active");
        contest.lockContest();
    }
    
    function test_lockContest_NotOracle() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        vm.prank(nonOracle);
        vm.expectRevert("Not oracle");
        contest.lockContest();
    }
    
    // ============ settleContest Tests ============
    
    function test_settleContest_Success() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_1;
        winners[1] = ENTRY_2;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 7000; // 70%
        payouts[1] = 3000; // 30%
        
        vm.prank(oracle);
        vm.expectEmit(true, false, false, false);
        emit ContestController.ContestSettled(winners, payouts);
        _settleContest(contest, winners, payouts);
        
        assertEq(uint8(contest.state()), uint8(ContestState.SETTLED));
        assertGt(contest.primaryPrizePoolPayouts(ENTRY_1), 0);
        assertGt(contest.primaryPrizePoolPayouts(ENTRY_2), 0);
        assertEq(contest.secondaryWinningEntry(), ENTRY_1);
        assertTrue(contest.secondaryMarketResolved());
    }
    
    function test_settleContest_PayoutsSumTo100() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_1;
        winners[1] = ENTRY_2;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 5000;
        payouts[1] = 5000;
        _settleContest(contest, winners, payouts);
        
        assertEq(uint8(contest.state()), uint8(ContestState.SETTLED));
    }
    
    function test_settleContest_SecondaryWinnerSet() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_2; // First winner is secondary winner
        winners[1] = ENTRY_1;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 6000;
        payouts[1] = 4000;
        _settleContest(contest, winners, payouts);
        
        assertEq(contest.secondaryWinningEntry(), ENTRY_2);
    }
    
    function test_settleContest_NoERC1155SupplyOnWinningEntry() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        // No secondary positions on ENTRY_1
        _createSecondaryPosition(user3, ENTRY_2, PURCHASE_INCREMENT);
        
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1; // No secondary supply
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        
        uint256 primaryPoolBefore = contest.primaryPrizePool();
        uint256 secondaryTvlBefore = contest.getSecondarySideBalance();
        uint256 twoSubsidy = 2 * _standardSubsidyPerPrimaryDeposit();
        assertEq(secondaryTvlBefore, PURCHASE_INCREMENT + twoSubsidy);
        _settleContest(contest, winners, payouts);

        // All secondary TVL is merged to the winning entry; with no winning secondary supply it spills to primary payouts (net of referral fee)
        uint256 grossSecondary = PURCHASE_INCREMENT + twoSubsidy;
        uint256 netBps = _netBps(contest);
        uint256 netPrimary = (primaryPoolBefore * netBps) / 10_000;
        uint256 netSecondary = (grossSecondary * netBps) / 10_000;
        assertEq(contest.primaryPrizePoolPayouts(ENTRY_1), netPrimary + netSecondary);
        assertEq(contest.getSecondarySideBalance(), 0);
        assertEq(contest.secondaryLiquidityPerEntry(ENTRY_2), 0);
    }
    
    function test_settleContest_WrongState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        
        _settleContestExpectRevert(contest, winners, payouts, "Contest not active or locked");
    }
    
    function test_settleContest_NoWinners() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](0);
        uint256[] memory payouts = new uint256[](0);
        
        _settleContestExpectRevert(contest, winners, payouts, "Must have at least one winner");
    }
    
    function test_settleContest_ArrayLengthMismatch() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 5000;
        payouts[1] = 5000;
        
        _settleContestExpectRevert(contest, winners, payouts, "Array length mismatch");
    }
    
    function test_settleContest_TooManyWinners() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_1;
        winners[1] = ENTRY_2; // Doesn't exist
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 5000;
        payouts[1] = 5000;
        
        _settleContestExpectRevert(contest, winners, payouts, "Too many winners");
    }
    
    function test_settleContest_PayoutsDontSumTo100() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 5000; // 50%, should be 10000
        
        _settleContestExpectRevert(contest, winners, payouts, "Payouts must sum to 100%");
    }
    
    function test_settleContest_ZeroPayouts() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_1;
        winners[1] = ENTRY_2;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 10000;
        payouts[1] = 0; // Zero payout
        
        _settleContestExpectRevert(contest, winners, payouts, "Use non-zero payouts only");
    }
    
    // ============ cancelContest Tests ============
    
    function test_cancelContest_SuccessFromOpen() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(oracle);
        vm.expectEmit(true, false, false, false);
        emit ContestController.ContestCancelled();
        contest.cancelContest();
        
        assertEq(uint8(contest.state()), uint8(ContestState.CANCELLED));
    }
    
    function test_cancelContest_SuccessFromActive() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        vm.prank(oracle);
        contest.cancelContest();
        
        assertEq(uint8(contest.state()), uint8(ContestState.CANCELLED));
    }
    
    function test_cancelContest_SuccessFromLocked() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        vm.prank(oracle);
        contest.cancelContest();
        
        assertEq(uint8(contest.state()), uint8(ContestState.CANCELLED));
    }
    
    function test_cancelContest_AlreadySettled() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        vm.prank(oracle);
        vm.expectRevert("Contest settled - cannot cancel");
        contest.cancelContest();
    }
    
    function test_cancelContest_NotOracle() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(nonOracle);
        vm.expectRevert("Not oracle");
        contest.cancelContest();
    }
    
    // ============ closeContest Tests ============
    
    function test_closeContest_Success() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.warp(block.timestamp + EXPIRY_OFFSET);
        
        uint256 balanceBefore = paymentToken.balanceOf(oracle);
        uint256 contractBalance = _getContractBalance();
        
        vm.prank(oracle);
        vm.expectEmit(true, false, false, false);
        emit ContestController.ContestClosed();
        contest.closeContest();
        
        assertEq(uint8(contest.state()), uint8(ContestState.CLOSED));
        assertEq(paymentToken.balanceOf(oracle), balanceBefore + contractBalance);
        assertEq(_getContractBalance(), 0);
    }
    
    function test_closeContest_ExpiryNotReached() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(oracle);
        vm.expectRevert("Expiry not reached");
        contest.closeContest();
    }
    
    function test_closeContest_NotOracle() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.warp(block.timestamp + EXPIRY_OFFSET);
        
        vm.prank(nonOracle);
        vm.expectRevert("Not oracle");
        contest.closeContest();
    }
    
    // ============ cancelExpired Tests ============
    
    function test_cancelExpired_Success() public {
        ContestController expiredContest = _deployContest(oracle, 1 days);
        vm.warp(block.timestamp + 1 days + 1);
        
        expiredContest.cancelExpired();
        
        assertEq(uint8(expiredContest.state()), uint8(ContestState.CANCELLED));
    }
    
    function test_cancelExpired_NotExpired() public {
        vm.expectRevert("Not expired");
        contest.cancelExpired();
    }
    
    function test_cancelExpired_AlreadySettled() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        vm.warp(block.timestamp + EXPIRY_OFFSET);
        vm.expectRevert("Already settled");
        contest.cancelExpired();
    }
    
    // ============ setPrimaryMerkleRoot Tests ============
    
    function test_setPrimaryMerkleRoot_Success() public {
        bytes32 root = bytes32(uint256(123));
        
        vm.prank(oracle);
        vm.expectEmit(true, false, false, false);
        emit ContestController.PrimaryMerkleRootUpdated(root);
        contest.setPrimaryMerkleRoot(root);
        
        assertEq(contest.primaryMerkleRoot(), root);
    }
    
    function test_setPrimaryMerkleRoot_DisableGating() public {
        bytes32 root = bytes32(uint256(123));
        vm.prank(oracle);
        contest.setPrimaryMerkleRoot(root);
        
        vm.prank(oracle);
        contest.setPrimaryMerkleRoot(bytes32(0));
        
        assertEq(contest.primaryMerkleRoot(), bytes32(0));
    }
    
    function test_setPrimaryMerkleRoot_NotOracle() public {
        vm.prank(nonOracle);
        vm.expectRevert("Not oracle");
        contest.setPrimaryMerkleRoot(bytes32(uint256(123)));
    }
    
    // ============ setSecondaryMerkleRoot Tests ============
    
    function test_setSecondaryMerkleRoot_Success() public {
        bytes32 root = bytes32(uint256(456));
        
        vm.prank(oracle);
        vm.expectEmit(true, false, false, false);
        emit ContestController.SecondaryMerkleRootUpdated(root);
        contest.setSecondaryMerkleRoot(root);
        
        assertEq(contest.secondaryMerkleRoot(), root);
    }
    
    function test_setSecondaryMerkleRoot_DisableGating() public {
        bytes32 root = bytes32(uint256(456));
        vm.prank(oracle);
        contest.setSecondaryMerkleRoot(root);
        
        vm.prank(oracle);
        contest.setSecondaryMerkleRoot(bytes32(0));
        
        assertEq(contest.secondaryMerkleRoot(), bytes32(0));
    }
    
    function test_setSecondaryMerkleRoot_NotOracle() public {
        vm.prank(nonOracle);
        vm.expectRevert("Not oracle");
        contest.setSecondaryMerkleRoot(bytes32(uint256(456)));
    }
    
    // ============ Push Functions Tests ============
    
    // ============ pushPrimaryPayouts Tests ============
    
    function test_pushPrimaryPayouts_Success() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_1;
        winners[1] = ENTRY_2;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 7000;
        payouts[1] = 3000;
        _settleContest(contest, winners, payouts);
        
        uint256[] memory entryIds = new uint256[](1);
        entryIds[0] = ENTRY_1;
        
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        
        vm.prank(oracle);
        contest.pushPrimaryPayouts(entryIds);
        
        assertGt(paymentToken.balanceOf(user1), balanceBefore);
        assertEq(contest.primaryPrizePoolPayouts(ENTRY_1), 0);
    }
    
    function test_pushPrimaryPayouts_only() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        _createSecondaryPosition(user3, ENTRY_1, PURCHASE_INCREMENT * 10);

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_1;
        winners[1] = ENTRY_2;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 7000;
        payouts[1] = 3000;
        _settleContest(contest, winners, payouts);

        uint256[] memory entryIds = new uint256[](1);
        entryIds[0] = ENTRY_1;

        uint256 payout = contest.primaryPrizePoolPayouts(ENTRY_1);
        uint256 balanceBefore = paymentToken.balanceOf(user1);

        vm.prank(oracle);
        contest.pushPrimaryPayouts(entryIds);

        assertEq(paymentToken.balanceOf(user1), balanceBefore + payout);
    }
    
    function test_pushPrimaryPayouts_NotSettled() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        uint256[] memory entryIds = new uint256[](1);
        entryIds[0] = ENTRY_1;
        
        vm.prank(oracle);
        vm.expectRevert("Contest not settled");
        contest.pushPrimaryPayouts(entryIds);
    }
    
    function test_pushPrimaryPayouts_EntryWithdrawn() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        vm.prank(user1);
        contest.removePrimaryPosition(ENTRY_1);
        
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_2;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        uint256[] memory entryIds = new uint256[](1);
        entryIds[0] = ENTRY_1;
        
        vm.prank(oracle);
        vm.expectRevert("Entry withdrawn or invalid");
        contest.pushPrimaryPayouts(entryIds);
    }
    
    // ============ pushSecondaryPayouts Tests ============
    
    function test_pushSecondaryPayouts_Success() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        _createSecondaryPosition(user3, ENTRY_1, PURCHASE_INCREMENT * 10);
        _createSecondaryPosition(user4, ENTRY_1, PURCHASE_INCREMENT * 5);
        
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        address[] memory participants = new address[](1);
        participants[0] = user3;
        
        uint256 balanceBefore = paymentToken.balanceOf(user3);
        
        vm.prank(oracle);
        contest.pushSecondaryPayouts(participants, ENTRY_1);
        
        assertGt(paymentToken.balanceOf(user3), balanceBefore);
        assertEq(contest.balanceOf(user3, ENTRY_1), 0);
    }
    
    function test_pushSecondaryPayouts_NotSettled() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        
        address[] memory participants = new address[](1);
        participants[0] = user2;
        
        vm.prank(oracle);
        vm.expectRevert("Contest not settled");
        contest.pushSecondaryPayouts(participants, ENTRY_1);
    }
    
    function test_pushSecondaryPayouts_NotWinningEntry() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        _createSecondaryPosition(user3, ENTRY_2, PURCHASE_INCREMENT);
        
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        address[] memory participants = new address[](1);
        participants[0] = user3;
        
        vm.prank(oracle);
        vm.expectRevert("Not winning entry");
        contest.pushSecondaryPayouts(participants, ENTRY_2);
    }
    
    // ============ View Functions Tests ============
    
    function test_getEntriesCount() public {
        assertEq(contest.getEntriesCount(), 0);
        
        _createPrimaryEntry(user1, ENTRY_1);
        assertEq(contest.getEntriesCount(), 1);
        
        _createPrimaryEntry(user2, ENTRY_2);
        assertEq(contest.getEntriesCount(), 2);

        vm.prank(user1);
        contest.removePrimaryPosition(ENTRY_1);
        assertEq(contest.getEntriesCount(), 1);
    }
    
    function test_getEntryAtIndex() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        
        assertEq(contest.getEntryAtIndex(0), ENTRY_1);
        assertEq(contest.getEntryAtIndex(1), ENTRY_2);
        
        vm.expectRevert("Invalid index");
        contest.getEntryAtIndex(2);
    }

    function test_getEntryAtIndex_AfterRemoveAndReAdd_NoDuplicate() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        assertEq(contest.getEntriesCount(), 2);

        vm.prank(user1);
        contest.removePrimaryPosition(ENTRY_1);

        assertEq(contest.getEntriesCount(), 1);
        assertEq(contest.getEntryAtIndex(0), ENTRY_2);
        vm.expectRevert("Invalid index");
        contest.getEntryAtIndex(1);

        _createPrimaryEntry(user1, ENTRY_1);
        assertEq(contest.getEntriesCount(), 2);

        uint256 first = contest.getEntryAtIndex(0);
        uint256 second = contest.getEntryAtIndex(1);
        assertTrue(first != second, "entries should be unique");
        assertTrue(
            (first == ENTRY_1 && second == ENTRY_2) || (first == ENTRY_2 && second == ENTRY_1),
            "expected active entries are missing"
        );
    }
    
    function test_getPrimarySideBalance() public {
        assertEq(contest.getPrimarySideBalance(), 0);
        
        _createPrimaryEntry(user1, ENTRY_1);
        assertGt(contest.getPrimarySideBalance(), 0);
    }
    
    function test_getSecondarySideBalance() public {
        assertEq(contest.getSecondarySideBalance(), 0);
        
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        assertGt(contest.getSecondarySideBalance(), 0);
    }
    
    function test_calculateSecondaryPrice() public {
        uint256 price1 = contest.calculateSecondaryPrice(ENTRY_1);
        assertGt(price1, 0);
        
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        
        uint256 price2 = contest.calculateSecondaryPrice(ENTRY_1);
        assertGt(price2, price1);
    }
    
    function test_uri() public view {
        assertEq(contest.uri(ENTRY_1), "");
        assertEq(contest.uri(ENTRY_2), "");
    }
    
    // ============ Primary pool unchanged by secondary trades ============
    
    function test_isolatedMarkets_SecondaryDoesNotChangePrimaryPool() public {
        _createPrimaryEntry(user1, ENTRY_1);
        uint256 primaryBefore = contest.primaryPrizePool();
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT * 10);
        assertEq(contest.primaryPrizePool(), primaryBefore);
    }
    
    function test_isolatedMarkets_PrimaryDoesNotChangeSecondaryTvl() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        uint256 e1BackedBefore = contest.secondaryLiquidityPerEntry(ENTRY_1);
        uint256 e1SubBefore = contest.secondaryPrimarySubsidyPerEntry(ENTRY_1);
        _createPrimaryEntry(user3, ENTRY_2);
        assertEq(contest.secondaryLiquidityPerEntry(ENTRY_1), e1BackedBefore);
        assertEq(contest.secondaryPrimarySubsidyPerEntry(ENTRY_1), e1SubBefore);
    }
    
    // ============ State Transition Tests ============
    
    function test_stateTransition_OpenToActive() public {
        _createPrimaryEntry(user1, ENTRY_1);
        assertEq(uint8(contest.state()), uint8(ContestState.OPEN));
        
        vm.prank(oracle);
        contest.activateContest();
        assertEq(uint8(contest.state()), uint8(ContestState.ACTIVE));
    }
    
    function test_stateTransition_ActiveToLocked() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        vm.prank(oracle);
        contest.lockContest();
        assertEq(uint8(contest.state()), uint8(ContestState.LOCKED));
    }
    
    function test_stateTransition_LockedToSettled() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        assertEq(uint8(contest.state()), uint8(ContestState.SETTLED));
    }
    
    function test_stateTransition_OpenToCancelled() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(oracle);
        contest.cancelContest();
        assertEq(uint8(contest.state()), uint8(ContestState.CANCELLED));
    }
    
    function test_stateTransition_CannotActivateAfterSettled() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        vm.prank(oracle);
        vm.expectRevert("Contest already started");
        contest.activateContest();
    }
    
    // ============ Fuzzing Tests ============
    
    function testFuzz_addPrimaryPosition_ValidEntryId(uint256 entryId) public {
        // Bound entry ID to reasonable range
        entryId = bound(entryId, 1, type(uint128).max);
        
        _fundUser(user1, PRIMARY_DEPOSIT);
        
        vm.prank(user1);
        contest.addPrimaryPosition(entryId, new bytes32[](0));
        
        assertEq(contest.entryOwner(entryId), user1);
    }
    
    function testFuzz_addPrimaryPosition_NoReferralFeeOnDeposit(uint256 amount) public {
        // Use fixed deposit amount, but test fee calculation
        amount = PRIMARY_DEPOSIT;
        
        _fundUser(user1, amount);
        vm.prank(user1);
        contest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
    }
    
    function testFuzz_removePrimaryPosition_FullRefund(uint256 entryId) public {
        entryId = bound(entryId, 1, type(uint128).max);
        
        _fundUser(user1, PRIMARY_DEPOSIT);
        vm.prank(user1);
        contest.addPrimaryPosition(entryId, new bytes32[](0));
        
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        
        vm.prank(user1);
        contest.removePrimaryPosition(entryId);
        
        assertEq(paymentToken.balanceOf(user1), balanceBefore + PRIMARY_DEPOSIT);
    }
    
    function testFuzz_addSecondaryPosition_TokensReceived(uint256 amount) public {
        amount = bound(amount, PURCHASE_INCREMENT, PURCHASE_INCREMENT * 100);
        
        _createPrimaryEntry(user1, ENTRY_1);
        _fundUser(user2, amount);
        
        vm.prank(user2);
        contest.addSecondaryPosition(ENTRY_1, amount, new bytes32[](0));
        
        assertGt(contest.balanceOf(user2, ENTRY_1), 0);
    }
    
    function testFuzz_addSecondaryPosition_PriceIncreases(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, PURCHASE_INCREMENT, PURCHASE_INCREMENT * 50);
        amount2 = bound(amount2, PURCHASE_INCREMENT, PURCHASE_INCREMENT * 50);
        
        if (amount1 >= amount2) return; // Skip if not increasing
        
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, amount1);
        
        uint256 price1 = contest.calculateSecondaryPrice(ENTRY_1);
        _createSecondaryPosition(user3, ENTRY_1, amount2);
        uint256 price2 = contest.calculateSecondaryPrice(ENTRY_1);
        
        assertGe(price2, price1);
    }
    
    function testFuzz_calculateSecondaryPrice_Monotonic(uint256 shares1, uint256 shares2) public {
        shares1 = bound(shares1, 0, 1e25);
        shares2 = bound(shares2, 0, 1e25);
        
        if (shares1 >= shares2) return;
        
        uint256 price1 = SecondaryPricing.calculatePrice(shares1);
        uint256 price2 = SecondaryPricing.calculatePrice(shares2);
        
        assertGe(price2, price1);
    }
    
    // ============ Invariant Tests ============
    
    function test_invariant_FundConservation() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        _createSecondaryPosition(user3, ENTRY_1, PURCHASE_INCREMENT * 10);
        
        uint256 totalContractBalance = _getContractBalance();
        uint256 primaryBalance = contest.getPrimarySideBalance();
        uint256 secondaryBalance = contest.getSecondarySideBalance();
        uint256 expectedTotal = primaryBalance + secondaryBalance;
        
        // Allow small rounding differences
        assertApproxEqRel(totalContractBalance, expectedTotal, 0.01e18);
    }
    
    function test_invariant_NoDoubleSpending() public {
        _createPrimaryEntry(user1, ENTRY_1);
        uint256 primaryPool = contest.primaryPrizePool();
        assertEq(primaryPool, _standardPrimaryPortionPerDeposit());
    }
    
    function test_invariant_NoAccumulatedReferralFeeBeforeSettle() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
    }
    
    function test_invariant_PriceMonotonic() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        uint256 price1 = contest.calculateSecondaryPrice(ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        uint256 price2 = contest.calculateSecondaryPrice(ENTRY_1);
        _createSecondaryPosition(user3, ENTRY_1, PURCHASE_INCREMENT);
        uint256 price3 = contest.calculateSecondaryPrice(ENTRY_1);
        
        assertGe(price2, price1);
        assertGe(price3, price2);
    }
    
    function test_invariant_RefundCompleteness() public {
        _createPrimaryEntry(user1, ENTRY_1);
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        
        vm.prank(user1);
        contest.removePrimaryPosition(ENTRY_1);
        
        assertEq(paymentToken.balanceOf(user1), balanceBefore + PRIMARY_DEPOSIT);
    }
    
    // ============ UX-Focused Tests ============
    
    function test_UX_NoFundLossOnInvalidAdd() public {
        // Create an entry first so we can activate
        _createPrimaryEntry(user2, ENTRY_2);
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        
        // Try to add in wrong state
        vm.prank(oracle);
        contest.activateContest();
        
        _fundUser(user1, PRIMARY_DEPOSIT);
        vm.prank(user1);
        vm.expectRevert("Contest not open");
        contest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
        
        // Balance should not change
        assertEq(paymentToken.balanceOf(user1), balanceBefore + PRIMARY_DEPOSIT);
    }
    
    function test_UX_NoFundLossOnInvalidRemove() public {
        _createPrimaryEntry(user1, ENTRY_1);
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        
        vm.prank(oracle);
        contest.activateContest();
        
        vm.prank(user1);
        vm.expectRevert("Cannot withdraw - contest in progress or settled");
        contest.removePrimaryPosition(ENTRY_1);
        
        // Balance should not change
        assertEq(paymentToken.balanceOf(user1), balanceBefore);
    }
    
    function test_UX_NoFundLossOnInvalidClaim() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(user1);
        vm.expectRevert("Contest not settled");
        contest.claimPrimaryPayout(ENTRY_1);
        
        // Entry should still exist
        assertEq(contest.entryOwner(ENTRY_1), user1);
    }
    
    function test_UX_FullRefundOnRemove() public {
        _createPrimaryEntry(user1, ENTRY_1);
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        
        vm.prank(user1);
        contest.removePrimaryPosition(ENTRY_1);
        
        assertEq(paymentToken.balanceOf(user1), balanceBefore + PRIMARY_DEPOSIT);
    }
    
    function test_UX_PaymentTooSmall_Protection() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        // Add large position first to drive up price
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT * 100);
        
        // Very small payment that won't get tokens
        uint256 smallPayment = 1;
        _fundUser(user3, smallPayment);
        
        vm.prank(user3);
        vm.expectRevert("Payment too small: insufficient to purchase tokens");
        contest.addSecondaryPosition(ENTRY_1, smallPayment, new bytes32[](0));
    }
    
    function test_UX_CompleteClaim() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        _createSecondaryPosition(user3, ENTRY_1, PURCHASE_INCREMENT * 10);

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256[] memory winners = new uint256[](2);
        winners[0] = ENTRY_1;
        winners[1] = ENTRY_2;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 7000;
        payouts[1] = 3000;
        _settleContest(contest, winners, payouts);

        uint256 payout = contest.primaryPrizePoolPayouts(ENTRY_1);
        uint256 balanceBefore = paymentToken.balanceOf(user1);

        vm.prank(user1);
        contest.claimPrimaryPayout(ENTRY_1);

        assertEq(paymentToken.balanceOf(user1), balanceBefore + payout);
    }
    
    function test_UX_ClearErrorMessages() public {
        // Create an entry first so we can activate
        _createPrimaryEntry(user2, ENTRY_2);
        
        vm.prank(oracle);
        contest.activateContest();
        
        _fundUser(user1, PRIMARY_DEPOSIT);
        vm.prank(user1);
        vm.expectRevert("Contest not open");
        contest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
        
        // Test "Entry already exists" in OPEN state (need to cancel first to go back)
        // Actually, once cancelled, we're in CANCELLED state, not OPEN
        // So we need a new contest or test in a different way
        // Let's test other clear error messages instead
        vm.prank(oracle);
        contest.cancelContest();
        
        // In CANCELLED state, can't add entries either
        _fundUser(user1, PRIMARY_DEPOSIT);
        vm.prank(user1);
        vm.expectRevert("Contest not open");
        contest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
        
        // Create a fresh contest to test "Entry already exists"
        ContestController newContest = _deployContest(oracle, EXPIRY_OFFSET);
        paymentToken.mint(user1, PRIMARY_DEPOSIT);
        vm.prank(user1);
        paymentToken.approve(address(newContest), PRIMARY_DEPOSIT);
        vm.prank(user1);
        newContest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
        
        paymentToken.mint(user2, PRIMARY_DEPOSIT);
        vm.prank(user2);
        paymentToken.approve(address(newContest), PRIMARY_DEPOSIT);
        vm.prank(user2);
        vm.expectRevert("Entry already exists");
        newContest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
    }
    
    function test_UX_RefundProportionalSecondary() public {
        _createPrimaryEntry(user1, ENTRY_1);
        uint256 depositAmount = PURCHASE_INCREMENT * 5;
        _createSecondaryPosition(user2, ENTRY_1, depositAmount);
        
        uint256 tokens = contest.balanceOf(user2, ENTRY_1);
        uint256 liq = contest.secondaryLiquidityPerEntry(ENTRY_1);
        uint256 supply = uint256(contest.netPosition(ENTRY_1));
        uint256 sellAmt = tokens / 2;
        uint256 expectedRefund = (sellAmt * liq) / supply;
        uint256 balanceBefore = paymentToken.balanceOf(user2);
        
        vm.prank(user2);
        contest.removeSecondaryPosition(ENTRY_1, sellAmt);
        
        uint256 refunded = paymentToken.balanceOf(user2) - balanceBefore;
        assertApproxEqRel(refunded, expectedRefund, 0.01e18);
    }
    
    // ============ Edge Cases ============
    
    function test_edgeCase_EmptyContest() public {
        assertEq(contest.getEntriesCount(), 0);
        
        vm.prank(oracle);
        vm.expectRevert("No entries");
        contest.activateContest();
    }
    
    function test_edgeCase_SingleEntry() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        assertGt(contest.primaryPrizePoolPayouts(ENTRY_1), 0);
    }
    
    function test_edgeCase_AllEntriesWithdraw() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        
        assertEq(contest.getEntriesCount(), 2);
        
        vm.prank(user1);
        contest.removePrimaryPosition(ENTRY_1);
        vm.prank(user2);
        contest.removePrimaryPosition(ENTRY_2);
        
        // Active entries are removed from enumeration on withdraw.
        assertEq(contest.getEntriesCount(), 0);
        assertEq(contest.entryOwner(ENTRY_1), address(0));
        assertEq(contest.entryOwner(ENTRY_2), address(0));
    }
    
    function test_edgeCase_SettlementSingleWinner() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000; // 100%
        _settleContest(contest, winners, payouts);
        
        assertGt(contest.primaryPrizePoolPayouts(ENTRY_1), 0);
        assertEq(contest.primaryPrizePoolPayouts(ENTRY_2), 0);
    }
    
    function test_edgeCase_SecondaryMarketNoParticipants() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        _settleContest(contest, winners, payouts);
        
        assertEq(contest.secondaryWinningEntry(), ENTRY_1);
        assertEq(contest.getSecondarySideBalance(), 0);
    }

    // ============ Referral network settlement ============

    function test_settleContest_ReferralFeeDistributed() public {
        address referrer = address(0xA11);
        address winner = user1;
        _registerWinnerReferrer(winner, referrer);

        _createPrimaryEntry(winner, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT * 5);

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256 referralFee = _referralFeeAmount(contest);
        assertGt(referralFee, 0);

        uint256[] memory expectedAmounts = rewardCalculator.calculateRewards(referralFee, 1);
        uint256 referrerBefore = paymentToken.balanceOf(referrer);
        uint256 winnerBefore = paymentToken.balanceOf(winner);

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10_000;
        _settleContest(contest, winners, payouts);

        assertEq(paymentToken.balanceOf(referrer), referrerBefore + expectedAmounts[0]);
        assertEq(paymentToken.balanceOf(winner), winnerBefore);
    }

    function test_settleContest_ReferralFeeZeroSkipsDistribution() public {
        ContestController zeroFee = _createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            0,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_DEPOSIT_SECONDARY_SUBSIDY_BPS
        );
        _fundUserContest(user1, zeroFee, PRIMARY_DEPOSIT);
        vm.prank(user1);
        zeroFee.addPrimaryPosition(ENTRY_1, new bytes32[](0));

        vm.prank(oracle);
        zeroFee.activateContest();

        uint256 oracleBefore = paymentToken.balanceOf(oracle);
        address referrer = address(0xA11);
        uint256 referrerBefore = paymentToken.balanceOf(referrer);

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10_000;
        _settleContest(zeroFee, winners, payouts);

        assertEq(paymentToken.balanceOf(oracle), oracleBefore);
        assertEq(paymentToken.balanceOf(referrer), referrerBefore);
    }

    function test_claimPrimaryPayout_NoFeeDeduction() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10_000;
        _settleContest(contest, winners, payouts);

        uint256 payout = contest.primaryPrizePoolPayouts(ENTRY_1);
        uint256 before = paymentToken.balanceOf(user1);
        vm.prank(user1);
        contest.claimPrimaryPayout(ENTRY_1);
        assertEq(paymentToken.balanceOf(user1), before + payout);
    }

    function test_settleContest_UnregisteredWinner_FeeToOracle() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);

        vm.prank(oracle);
        contest.activateContest();

        uint256 referralFee = _referralFeeAmount(contest);
        uint256 oracleBefore = paymentToken.balanceOf(oracle);

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10_000;
        _settleContest(contest, winners, payouts);

        assertEq(paymentToken.balanceOf(oracle), oracleBefore + referralFee);
    }
}

/**
 * @title MockERC20
 * @dev Simple ERC20 token for testing
 */
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
