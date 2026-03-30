// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ContestController.sol";
import "../src/ContestFactory.sol";
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
 * All tests respect standard settings from agents.md:
 * - PRIMARY_DEPOSIT = 25e18 ($25)
 * - ORACLE_FEE_BPS = 500 (5%)
 * - PRIMARY_ENTRY_INVESTMENT_SHARE_BPS = 500 (5%)
 * - PURCHASE_INCREMENT = 10e18 ($10)
 */
contract ContestControllerTest is Test {
    // Standard settings from agents.md
    uint256 public constant PRIMARY_DEPOSIT = 25e18; // $25
    uint256 public constant PURCHASE_INCREMENT = 10e18; // $10
    uint256 public constant ORACLE_FEE_BPS = 500; // 5%
    uint256 public constant PRIMARY_ENTRY_INVESTMENT_SHARE_BPS = 500; // 5%
    
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
    ContestFactory public factory;
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
        // Deploy mock ERC20 token
        paymentToken = new MockERC20("Payment Token", "PAY", 18);
        
        // Deploy factory
        factory = new ContestFactory();
        
        // Create contest
        address contestAddress = factory.createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            ORACLE_FEE_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_ENTRY_INVESTMENT_SHARE_BPS
        );
        
        contest = ContestController(contestAddress);
        
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
    function _deployContest(
        address _oracle,
        uint256 _expiryOffset
    ) internal returns (ContestController) {
        address contestAddress = factory.createContest(
            address(paymentToken),
            _oracle,
            PRIMARY_DEPOSIT,
            ORACLE_FEE_BPS,
            block.timestamp + _expiryOffset,
            PRIMARY_ENTRY_INVESTMENT_SHARE_BPS
        );
        return ContestController(contestAddress);
    }
    
    /**
     * @notice Fund user and approve contest
     */
    function _fundUser(address user, uint256 amount) internal {
        paymentToken.mint(user, amount);
        vm.prank(user);
        paymentToken.approve(address(contest), amount);
    }
    
    /**
     * @notice Create primary entry
     */
    function _createPrimaryEntry(address user, uint256 entryId) internal {
        _fundUser(user, PRIMARY_DEPOSIT);
        vm.prank(user);
        contest.addPrimaryPosition(entryId, new bytes32[](0));
    }
    
    /**
     * @notice Create secondary position
     */
    function _createSecondaryPosition(address user, uint256 entryId, uint256 amount) internal {
        _fundUser(user, amount);
        vm.prank(user);
        contest.addSecondaryPosition(entryId, amount, new bytes32[](0));
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
    function _calculateExpectedOracleFee(uint256 amount) internal pure returns (uint256) {
        return (amount * ORACLE_FEE_BPS) / 10000;
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
        assertEq(newContest.oracleFeeBps(), ORACLE_FEE_BPS);
        assertEq(newContest.primaryEntryInvestmentShareBps(), PRIMARY_ENTRY_INVESTMENT_SHARE_BPS);
        assertEq(uint8(newContest.state()), uint8(ContestState.OPEN));
    }
    
    function test_constructor_InvalidPaymentToken() public {
        vm.expectRevert("Invalid payment token");
        factory.createContest(
            address(0),
            oracle,
            PRIMARY_DEPOSIT,
            ORACLE_FEE_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_ENTRY_INVESTMENT_SHARE_BPS
        );
    }
    
    function test_constructor_InvalidOracle() public {
        vm.expectRevert("Invalid oracle");
        factory.createContest(
            address(paymentToken),
            address(0),
            PRIMARY_DEPOSIT,
            ORACLE_FEE_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_ENTRY_INVESTMENT_SHARE_BPS
        );
    }
    
    function test_constructor_InvalidDepositAmount() public {
        vm.expectRevert("Invalid deposit amount");
        factory.createContest(
            address(paymentToken),
            oracle,
            0,
            ORACLE_FEE_BPS,
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_ENTRY_INVESTMENT_SHARE_BPS
        );
    }
    
    function test_constructor_OracleFeeTooHigh() public {
        vm.expectRevert("Oracle fee too high");
        factory.createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            1001, // > 10%
            block.timestamp + EXPIRY_OFFSET,
            PRIMARY_ENTRY_INVESTMENT_SHARE_BPS
        );
    }
    
    function test_constructor_ExpiryInPast() public {
        vm.expectRevert("Expiry in past");
        factory.createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            ORACLE_FEE_BPS,
            block.timestamp - 1,
            PRIMARY_ENTRY_INVESTMENT_SHARE_BPS
        );
    }
    
    function test_constructor_InvalidPrimaryEntryInvestmentShare() public {
        vm.expectRevert("Invalid primary entry investment share");
        factory.createContest(
            address(paymentToken),
            oracle,
            PRIMARY_DEPOSIT,
            ORACLE_FEE_BPS,
            block.timestamp + EXPIRY_OFFSET,
            10001 // > 100%
        );
    }
    
    // ============ Primary Position Tests ============
    
    // ============ addPrimaryPosition Tests ============
    
    function test_addPrimaryPosition_Success() public {
        _fundUser(user1, PRIMARY_DEPOSIT);
        
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        uint256 contractBalanceBefore = _getContractBalance();
        uint256 oracleFeeBefore = contest.accumulatedOracleFee();
        
        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit ContestController.PrimaryPositionAdded(user1, ENTRY_1);
        contest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
        
        assertEq(contest.entryOwner(ENTRY_1), user1);
        assertEq(contest.getEntriesCount(), 1);
        assertEq(contest.getEntryAtIndex(0), ENTRY_1);
        assertEq(paymentToken.balanceOf(user1), balanceBefore - PRIMARY_DEPOSIT);
        assertEq(_getContractBalance(), contractBalanceBefore + PRIMARY_DEPOSIT);
        
        assertEq(contest.accumulatedOracleFee(), oracleFeeBefore);
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
    
    function test_addPrimaryPosition_OracleFeeNotAccumulated() public {
        _fundUser(user1, PRIMARY_DEPOSIT * 2);
        _createPrimaryEntry(user1, ENTRY_1);
        
        uint256 fee1 = contest.accumulatedOracleFee();
        assertEq(fee1, 0);
        
        _fundUser(user2, PRIMARY_DEPOSIT);
        vm.prank(user2);
        contest.addPrimaryPosition(ENTRY_2, new bytes32[](0));
        
        uint256 fee2 = contest.accumulatedOracleFee();
        assertEq(fee2, fee1);
    }
    
    // ============ removePrimaryPosition Tests ============
    
    function test_removePrimaryPosition_SuccessInOpenState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        uint256 contractBalanceBefore = _getContractBalance();
        uint256 oracleFeeBefore = contest.accumulatedOracleFee();
        
        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit ContestController.PrimaryPositionRemoved(ENTRY_1, user1);
        contest.removePrimaryPosition(ENTRY_1);
        
        assertEq(contest.entryOwner(ENTRY_1), address(0));
        assertEq(paymentToken.balanceOf(user1), balanceBefore + PRIMARY_DEPOSIT);
        assertEq(_getContractBalance(), contractBalanceBefore - PRIMARY_DEPOSIT);
        assertEq(contest.accumulatedOracleFee(), oracleFeeBefore);
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
        uint256 payout = contest.primaryPrizePoolPayouts(ENTRY_1);
        uint256 expectedNetPayout = payout - _calculateExpectedOracleFee(payout);
        uint256 balanceBefore = paymentToken.balanceOf(user1);
        
        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit ContestController.PrimaryPayoutClaimed(user1, ENTRY_1, expectedNetPayout);
        contest.claimPrimaryPayout(ENTRY_1);
        
        assertEq(paymentToken.balanceOf(user1), balanceBefore + expectedNetPayout);
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

        vm.prank(oracle);
        contest.settleContest(winners, payouts);

        uint256 payout = contest.primaryPrizePoolPayouts(ENTRY_1);
        uint256 netPrize = payout - _calculateExpectedOracleFee(payout);
        uint256 balanceBefore = paymentToken.balanceOf(user1);

        vm.prank(user1);
        contest.claimPrimaryPayout(ENTRY_1);

        assertEq(paymentToken.balanceOf(user1), balanceBefore + netPrize);
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
        
        uint256 oracleFeeBefore = contest.accumulatedOracleFee();
        _fundUser(user2, PURCHASE_INCREMENT);
        
        vm.prank(user2);
        contest.addSecondaryPosition(ENTRY_1, PURCHASE_INCREMENT, new bytes32[](0));
        
        uint256 oracleFeeAfter = contest.accumulatedOracleFee();
        assertEq(oracleFeeAfter, oracleFeeBefore);
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
        uint256 investmentAmount = (amount * PRIMARY_ENTRY_INVESTMENT_SHARE_BPS) / 10000;
        uint256 remainingAmount = amount - investmentAmount;

        _createSecondaryPosition(user2, ENTRY_1, amount);

        // Buyer gets the buyer-leg collateral, and entry owner gets the owner-leg collateral.
        assertEq(contest.secondaryDepositedPerEntry(user2, ENTRY_1), remainingAmount);
        assertEq(contest.secondaryDepositedPerEntry(user1, ENTRY_1), investmentAmount);

        uint256 userBalBefore = contest.balanceOf(user2, ENTRY_1);
        uint256 tokenToSell = userBalBefore / 2;
        assertGt(tokenToSell, 0);

        uint256 depositedBefore = contest.secondaryDepositedPerEntry(user2, ENTRY_1);
        uint256 expectedPrincipalToForfeit = (depositedBefore * tokenToSell) / userBalBefore;

        vm.prank(user2);
        contest.removeSecondaryPosition(ENTRY_1, tokenToSell);

        assertEq(contest.secondaryDepositedPerEntry(user2, ENTRY_1), depositedBefore - expectedPrincipalToForfeit);
        // Entry owner position is independent; selling buyer tokens shouldn't change owner attribution.
        assertEq(contest.secondaryDepositedPerEntry(user1, ENTRY_1), investmentAmount);
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
        uint256 balanceBefore = paymentToken.balanceOf(user3);
        
        vm.prank(user3);
        contest.claimSecondaryPayout(ENTRY_1);
        
        assertEq(contest.balanceOf(user3, ENTRY_1), 0);
        assertGt(paymentToken.balanceOf(user3), balanceBefore);
    }

    function test_secondaryDepositedPerEntry_claimResetsToZero() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);

        uint256 amount = PURCHASE_INCREMENT * 10;
        uint256 investmentAmount = (amount * PRIMARY_ENTRY_INVESTMENT_SHARE_BPS) / 10000;
        uint256 remainingAmount = amount - investmentAmount;

        _createSecondaryPosition(user3, ENTRY_1, amount);

        assertEq(contest.secondaryDepositedPerEntry(user3, ENTRY_1), remainingAmount);
        assertEq(contest.secondaryDepositedPerEntry(user1, ENTRY_1), investmentAmount);
        assertGt(contest.balanceOf(user1, ENTRY_1), 0); // owner-leg tokens exist

        vm.prank(oracle);
        contest.activateContest();
        vm.prank(oracle);
        contest.lockContest();

        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;

        vm.prank(oracle);
        contest.settleContest(winners, payouts);

        vm.prank(user3);
        contest.claimSecondaryPayout(ENTRY_1);

        assertEq(contest.balanceOf(user3, ENTRY_1), 0);
        assertEq(contest.secondaryDepositedPerEntry(user3, ENTRY_1), 0);
        // Owner position remains; only the claimant's tokens were burned.
        assertEq(contest.secondaryDepositedPerEntry(user1, ENTRY_1), investmentAmount);
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
        vm.prank(user3);
        contest.claimSecondaryPayout(ENTRY_1);
        
        uint256 user3Payout = paymentToken.balanceOf(user3);
        assertGt(user3Payout, 0);
        
        uint256 bal4Before = paymentToken.balanceOf(user4);
        vm.prank(user4);
        contest.claimSecondaryPayout(ENTRY_1);
        assertGt(paymentToken.balanceOf(user4), bal4Before);
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
        contest.settleContest(winners, payouts);
        
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
        
        uint256 payoutBefore = contest.primaryPrizePoolPayouts(ENTRY_1);
        uint256 secondaryTvlBefore = contest.getSecondarySideBalance();
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
        // Winning entry has no secondary supply; loser entry keeps its per-entry liquidity (isolated markets)
        uint256 payoutAfter = contest.primaryPrizePoolPayouts(ENTRY_1);
        assertGt(payoutAfter, payoutBefore);
        assertEq(contest.getSecondarySideBalance(), secondaryTvlBefore);
    }
    
    function test_settleContest_WrongState() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 10000;
        
        vm.prank(oracle);
        vm.expectRevert("Contest not active or locked");
        contest.settleContest(winners, payouts);
    }
    
    function test_settleContest_NoWinners() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](0);
        uint256[] memory payouts = new uint256[](0);
        
        vm.prank(oracle);
        vm.expectRevert("Must have at least one winner");
        contest.settleContest(winners, payouts);
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
        
        vm.prank(oracle);
        vm.expectRevert("Array length mismatch");
        contest.settleContest(winners, payouts);
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
        
        vm.prank(oracle);
        vm.expectRevert("Too many winners");
        contest.settleContest(winners, payouts);
    }
    
    function test_settleContest_PayoutsDontSumTo100() public {
        _createPrimaryEntry(user1, ENTRY_1);
        vm.prank(oracle);
        contest.activateContest();
        
        uint256[] memory winners = new uint256[](1);
        winners[0] = ENTRY_1;
        uint256[] memory payouts = new uint256[](1);
        payouts[0] = 5000; // 50%, should be 10000
        
        vm.prank(oracle);
        vm.expectRevert("Payouts must sum to 100%");
        contest.settleContest(winners, payouts);
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
        
        vm.prank(oracle);
        vm.expectRevert("Use non-zero payouts only");
        contest.settleContest(winners, payouts);
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
        vm.warp(block.timestamp + EXPIRY_OFFSET);
        vm.expectRevert("Already settled");
        contest.cancelExpired();
    }
    
    // ============ claimOracleFee Tests ============
    
    function test_claimOracleFee_Success() public {
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
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
        vm.prank(user1);
        contest.claimPrimaryPayout(ENTRY_1);
        
        uint256 fee = contest.accumulatedOracleFee();
        assertGt(fee, 0);
        
        uint256 balanceBefore = paymentToken.balanceOf(oracle);
        
        vm.prank(oracle);
        contest.claimOracleFee();
        
        assertEq(paymentToken.balanceOf(oracle), balanceBefore + fee);
        assertEq(contest.accumulatedOracleFee(), 0);
    }
    
    function test_claimOracleFee_NotOracle() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        vm.prank(nonOracle);
        vm.expectRevert("Not oracle");
        contest.claimOracleFee();
    }
    
    function test_claimOracleFee_NoFeeToClaim() public {
        vm.prank(oracle);
        vm.expectRevert("No fee to claim");
        contest.claimOracleFee();
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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

        vm.prank(oracle);
        contest.settleContest(winners, payouts);

        uint256[] memory entryIds = new uint256[](1);
        entryIds[0] = ENTRY_1;

        uint256 payout = contest.primaryPrizePoolPayouts(ENTRY_1);
        uint256 netPrize = payout - _calculateExpectedOracleFee(payout);
        uint256 balanceBefore = paymentToken.balanceOf(user1);

        vm.prank(oracle);
        contest.pushPrimaryPayouts(entryIds);

        assertEq(paymentToken.balanceOf(user1), balanceBefore + netPrize);
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
    }
    
    function test_getEntryAtIndex() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createPrimaryEntry(user2, ENTRY_2);
        
        assertEq(contest.getEntryAtIndex(0), ENTRY_1);
        assertEq(contest.getEntryAtIndex(1), ENTRY_2);
        
        vm.expectRevert("Invalid index");
        contest.getEntryAtIndex(2);
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
    
    function test_getPrimarySideShareBps() public {
        assertEq(contest.getPrimarySideShareBps(), 0);
        
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        
        uint256 share = contest.getPrimarySideShareBps();
        assertGe(share, 0);
        assertLe(share, 10000);
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
    
    // ============ Isolated markets (no cross-subsidy) ============
    
    function test_isolatedMarkets_SecondaryDoesNotChangePrimaryPool() public {
        _createPrimaryEntry(user1, ENTRY_1);
        uint256 primaryBefore = contest.primaryPrizePool();
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT * 10);
        assertEq(contest.primaryPrizePool(), primaryBefore);
    }
    
    function test_isolatedMarkets_PrimaryDoesNotChangeSecondaryTvl() public {
        _createPrimaryEntry(user1, ENTRY_1);
        _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);
        uint256 secBefore = contest.getSecondarySideBalance();
        _createPrimaryEntry(user3, ENTRY_2);
        assertEq(contest.getSecondarySideBalance(), secBefore);
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
    
    function testFuzz_addPrimaryPosition_OracleFeeNotAccumulated(uint256 amount) public {
        // Use fixed deposit amount, but test fee calculation
        amount = PRIMARY_DEPOSIT;
        
        _fundUser(user1, amount);
        uint256 feeBefore = contest.accumulatedOracleFee();
        
        vm.prank(user1);
        contest.addPrimaryPosition(ENTRY_1, new bytes32[](0));
        
        uint256 feeAfter = contest.accumulatedOracleFee();
        assertEq(feeAfter, feeBefore);
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
        uint256 oracleFee = contest.accumulatedOracleFee();
        
        uint256 expectedTotal = primaryBalance + secondaryBalance + oracleFee;
        
        // Allow small rounding differences
        assertApproxEqRel(totalContractBalance, expectedTotal, 0.01e18);
    }
    
    function test_invariant_NoDoubleSpending() public {
        _createPrimaryEntry(user1, ENTRY_1);
        uint256 primaryPool = contest.primaryPrizePool();
        assertEq(primaryPool, PRIMARY_DEPOSIT);
    }
    
    function test_invariant_OracleFeeBounded() public {
        _createPrimaryEntry(user1, ENTRY_1);
        
        uint256 fee = contest.accumulatedOracleFee();
        assertEq(fee, 0);
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

        vm.prank(oracle);
        contest.settleContest(winners, payouts);

        uint256 payout = contest.primaryPrizePoolPayouts(ENTRY_1);
        uint256 netPrize = payout - _calculateExpectedOracleFee(payout);
        uint256 balanceBefore = paymentToken.balanceOf(user1);

        vm.prank(user1);
        contest.claimPrimaryPayout(ENTRY_1);

        assertEq(paymentToken.balanceOf(user1), balanceBefore + netPrize);
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
        
        // Entries array is not cleared, but owners are set to address(0)
        assertEq(contest.getEntriesCount(), 2);
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
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
        
        vm.prank(oracle);
        contest.settleContest(winners, payouts);
        
        assertEq(contest.secondaryWinningEntry(), ENTRY_1);
        assertEq(contest.getSecondarySideBalance(), 0);
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
