// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/src/Test.sol";
import { ResolutionDAO } from "../src/dao/ResolutionDAO.sol";
import { AgiArenaCore } from "../src/core/AgiArenaCore.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Mock USDC token for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title ResolutionDAOSettlementTest
/// @notice Test suite for Story 3.3: Permissionless Settlement with Fee Collection
contract ResolutionDAOSettlementTest is Test {
    ResolutionDAO public resolutionDAO;
    AgiArenaCore public agiArenaCore;
    MockUSDC public usdc;

    address public keeper1 = address(0x1);
    address public keeper2 = address(0x2);
    address public creator = address(0x3);
    address public filler = address(0x4);
    address public feeRecipient = address(0x5);
    address public settler = address(0x6); // Random address to test permissionless settlement

    uint256 public constant INITIAL_BALANCE = 10000 * 1e6; // 10,000 USDC
    uint256 public constant BET_AMOUNT = 1000 * 1e6; // 1,000 USDC
    uint256 public constant PLATFORM_FEE_BPS = 10; // 0.1%

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy AgiArenaCore
        agiArenaCore = new AgiArenaCore(address(usdc), feeRecipient);

        // Deploy ResolutionDAO with keeper1 as initial keeper
        resolutionDAO = new ResolutionDAO(keeper1, address(agiArenaCore));

        // Add keeper2 via governance
        // With only 1 keeper, keeper1's vote is enough to reach quorum
        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(keeper2);
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        // Execute the proposal (keeper1 vote = 100% with 1 keeper)
        vm.prank(keeper1);
        resolutionDAO.executeKeeperProposal(proposalId);

        // Verify keeper2 is now a keeper
        assertTrue(resolutionDAO.isKeeper(keeper2), "keeper2 should be added");

        // Fund test accounts
        usdc.mint(creator, INITIAL_BALANCE);
        usdc.mint(filler, INITIAL_BALANCE);

        // Approve AgiArenaCore to spend USDC
        vm.prank(creator);
        usdc.approve(address(agiArenaCore), type(uint256).max);
        vm.prank(filler);
        usdc.approve(address(agiArenaCore), type(uint256).max);

        // Approve ResolutionDAO to transfer from AgiArenaCore (for settlement)
        // NOTE: This simulates the approval that would be set up in deployment
        vm.prank(address(agiArenaCore));
        usdc.approve(address(resolutionDAO), type(uint256).max);
    }

    /// @notice Helper to create a bet and match it
    function _createAndMatchBet() internal returns (uint256 betId) {
        bytes32 betHash = keccak256("test-portfolio");
        string memory jsonRef = "test-ref-123";

        // Creator places bet
        vm.prank(creator);
        betId = agiArenaCore.placeBet(betHash, jsonRef, BET_AMOUNT);

        // Filler matches bet
        vm.prank(filler);
        agiArenaCore.matchBet(betId, BET_AMOUNT);
    }

    /// @notice Helper to reach consensus with keepers
    function _reachConsensus(uint256 betId, bool creatorWins, int256 score1, int256 score2) internal {
        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, score1, creatorWins);

        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, score2, creatorWins);
    }

    // ============ settleBet Tests ============

    function test_SettleBet_Success_CreatorWins() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500); // Creator wins with +5% score

        // Anyone can settle
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        // Verify settlement state
        assertTrue(resolutionDAO.betSettled(betId), "Bet should be settled");
        assertEq(resolutionDAO.betWinner(betId), creator, "Creator should be winner");

        // Verify payout calculation (totalPot - fee)
        uint256 totalPot = BET_AMOUNT * 2;
        uint256 expectedFee = (totalPot * PLATFORM_FEE_BPS) / 10000;
        uint256 expectedPayout = totalPot - expectedFee;
        assertEq(resolutionDAO.winnerPayouts(betId), expectedPayout, "Winner payout incorrect");
        assertEq(resolutionDAO.accumulatedFees(), expectedFee, "Accumulated fees incorrect");
    }

    function test_SettleBet_Success_FillerWins() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, false, -300, -300); // Filler wins with -3% score

        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        assertTrue(resolutionDAO.betSettled(betId), "Bet should be settled");
        assertEq(resolutionDAO.betWinner(betId), filler, "Filler should be winner");
    }

    function test_SettleBet_RevertNoConsensus() public {
        uint256 betId = _createAndMatchBet();
        // Only one keeper votes - no consensus
        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.ConsensusNotReached.selector, betId));
        resolutionDAO.settleBet(betId);
    }

    function test_SettleBet_RevertAlreadySettled() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        // Try to settle again
        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.BetAlreadySettled.selector, betId));
        resolutionDAO.settleBet(betId);
    }

    function test_SettleBet_Tie_BothPartiesPaid() public {
        uint256 betId = _createAndMatchBet();
        // Tie: both scores exactly 0
        _reachConsensus(betId, true, 0, 0);

        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        // Verify tie state
        assertTrue(resolutionDAO.isTieBet(betId), "Should be marked as tie");
        assertTrue(resolutionDAO.betSettled(betId), "Bet should be settled");

        // Both parties should have payouts recorded
        assertGt(resolutionDAO.winnerPayouts(betId), 0, "Creator payout should be set");
        assertGt(resolutionDAO.loserPayouts(betId), 0, "Filler payout should be set");

        // Verify fee was deducted proportionally
        uint256 totalPot = BET_AMOUNT * 2;
        uint256 expectedFee = (totalPot * PLATFORM_FEE_BPS) / 10000;
        assertEq(resolutionDAO.accumulatedFees(), expectedFee, "Fee should be collected");
    }

    // ============ claimWinnings Tests ============

    function test_ClaimWinnings_Success() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        uint256 expectedPayout = resolutionDAO.winnerPayouts(betId);
        uint256 creatorBalanceBefore = usdc.balanceOf(creator);

        vm.prank(creator);
        resolutionDAO.claimWinnings(betId);

        assertEq(usdc.balanceOf(creator), creatorBalanceBefore + expectedPayout, "Creator should receive payout");
        assertTrue(resolutionDAO.winningsClaimed(betId), "Winnings should be marked claimed");
    }

    function test_ClaimWinnings_RevertNotWinner() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500); // Creator wins
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        // Filler tries to claim (not winner)
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.NotWinner.selector, filler, betId));
        resolutionDAO.claimWinnings(betId);
    }

    function test_ClaimWinnings_RevertAlreadyClaimed() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        vm.prank(creator);
        resolutionDAO.claimWinnings(betId);

        // Try to claim again
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.NoWinningsAvailable.selector, betId));
        resolutionDAO.claimWinnings(betId);
    }

    function test_ClaimWinnings_Tie_BothCanClaim() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 0, 0); // Tie
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        uint256 creatorBalanceBefore = usdc.balanceOf(creator);
        uint256 fillerBalanceBefore = usdc.balanceOf(filler);

        // Creator claims
        vm.prank(creator);
        resolutionDAO.claimWinnings(betId);

        // Filler claims
        vm.prank(filler);
        resolutionDAO.claimWinnings(betId);

        // Both should have received refunds
        assertGt(usdc.balanceOf(creator), creatorBalanceBefore, "Creator should receive refund");
        assertGt(usdc.balanceOf(filler), fillerBalanceBefore, "Filler should receive refund");
    }

    function test_ClaimWinnings_RevertNotSettled() public {
        uint256 betId = _createAndMatchBet();
        // Don't settle

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InvalidBetStatus.selector, betId));
        resolutionDAO.claimWinnings(betId);
    }

    // ============ withdrawPlatformFees Tests ============

    function test_WithdrawPlatformFees_Success() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        uint256 expectedFees = resolutionDAO.accumulatedFees();
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        // Anyone can trigger withdrawal
        vm.prank(settler);
        resolutionDAO.withdrawPlatformFees();

        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + expectedFees, "Fee recipient should receive fees");
        assertEq(resolutionDAO.accumulatedFees(), 0, "Accumulated fees should be reset");
    }

    function test_WithdrawPlatformFees_RevertNoFees() public {
        // No settlements = no fees
        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.NoWinningsAvailable.selector, 0));
        resolutionDAO.withdrawPlatformFees();
    }

    // ============ View Function Tests ============

    function test_CanSettleBet_True() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        assertTrue(resolutionDAO.canSettleBet(betId), "Should be settleable");
    }

    function test_CanSettleBet_False_NoConsensus() public {
        uint256 betId = _createAndMatchBet();
        // No consensus

        assertFalse(resolutionDAO.canSettleBet(betId), "Should not be settleable without consensus");
    }

    function test_CanSettleBet_False_AlreadySettled() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        assertFalse(resolutionDAO.canSettleBet(betId), "Should not be settleable after settlement");
    }

    function test_GetBetSettlementStatus() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        (bool isSettled, address winner, uint256 payout, bool claimed) = resolutionDAO.getBetSettlementStatus(betId);

        assertTrue(isSettled, "Should be settled");
        assertEq(winner, creator, "Winner should be creator");
        assertGt(payout, 0, "Payout should be > 0");
        assertFalse(claimed, "Should not be claimed yet");
    }

    function test_GetAccumulatedFees() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        uint256 totalPot = BET_AMOUNT * 2;
        uint256 expectedFee = (totalPot * PLATFORM_FEE_BPS) / 10000;

        assertEq(resolutionDAO.getAccumulatedFees(), expectedFee, "Accumulated fees incorrect");
    }

    // ============ Fee Calculation Tests ============

    function test_FeeCalculation_Correct() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        uint256 totalPot = BET_AMOUNT * 2; // 2000 USDC
        uint256 expectedFee = (totalPot * 10) / 10000; // 0.1% = 0.2 USDC = 200000 (6 decimals)
        uint256 expectedPayout = totalPot - expectedFee;

        assertEq(resolutionDAO.accumulatedFees(), expectedFee, "Fee calculation incorrect");
        assertEq(resolutionDAO.winnerPayouts(betId), expectedPayout, "Payout calculation incorrect");
    }

    function testFuzz_FeeCalculation(uint256 amount) public {
        // Bound amount to reasonable range (1 USDC to 1M USDC)
        amount = bound(amount, 1e6, 1_000_000 * 1e6);

        // Fund accounts with enough
        usdc.mint(creator, amount);
        usdc.mint(filler, amount);
        vm.prank(creator);
        usdc.approve(address(agiArenaCore), type(uint256).max);
        vm.prank(filler);
        usdc.approve(address(agiArenaCore), type(uint256).max);

        bytes32 betHash = keccak256(abi.encode("fuzz-portfolio", amount));
        vm.prank(creator);
        uint256 betId = agiArenaCore.placeBet(betHash, "fuzz-ref", amount);
        vm.prank(filler);
        agiArenaCore.matchBet(betId, amount);

        _reachConsensus(betId, true, 100, 100);
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        uint256 totalPot = amount * 2;
        uint256 expectedFee = (totalPot * 10) / 10000;

        // Fee should always be exactly 0.1%
        assertEq(resolutionDAO.accumulatedFees(), expectedFee, "Fee should be 0.1% of pot");
    }

    // ============ Event Tests ============

    // Event declarations for testing
    event BetSettled(
        uint256 indexed betId,
        address indexed winner,
        address loser,
        uint256 totalPot,
        uint256 platformFee,
        uint256 winnerPayout
    );

    event WinningsClaimed(uint256 indexed betId, address indexed winner, uint256 amount);

    event PlatformFeesWithdrawn(address indexed recipient, uint256 amount);

    function test_BetSettled_Event() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        uint256 totalPot = BET_AMOUNT * 2;
        uint256 expectedFee = (totalPot * PLATFORM_FEE_BPS) / 10000;
        uint256 expectedPayout = totalPot - expectedFee;

        vm.expectEmit(true, true, false, true);
        emit BetSettled(betId, creator, filler, totalPot, expectedFee, expectedPayout);

        vm.prank(settler);
        resolutionDAO.settleBet(betId);
    }

    function test_WinningsClaimed_Event() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        uint256 expectedPayout = resolutionDAO.winnerPayouts(betId);

        vm.expectEmit(true, true, false, true);
        emit WinningsClaimed(betId, creator, expectedPayout);

        vm.prank(creator);
        resolutionDAO.claimWinnings(betId);
    }

    function test_PlatformFeesWithdrawn_Event() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);
        vm.prank(settler);
        resolutionDAO.settleBet(betId);

        uint256 expectedFees = resolutionDAO.accumulatedFees();

        vm.expectEmit(true, false, false, true);
        emit PlatformFeesWithdrawn(feeRecipient, expectedFees);

        vm.prank(settler);
        resolutionDAO.withdrawPlatformFees();
    }
}
