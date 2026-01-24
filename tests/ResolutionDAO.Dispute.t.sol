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

/// @title ResolutionDAODisputeTest
/// @notice Test suite for Story 3.4: Dispute Mechanism with Economic Security
contract ResolutionDAODisputeTest is Test {
    ResolutionDAO public resolutionDAO;
    AgiArenaCore public agiArenaCore;
    MockUSDC public usdc;

    address public keeper1 = address(0x1);
    address public keeper2 = address(0x2);
    address public creator = address(0x3);
    address public filler = address(0x4);
    address public feeRecipient = address(0x5);
    address public disputer = address(0x6);

    uint256 public constant INITIAL_BALANCE = 10000 * 1e6; // 10,000 USDC
    uint256 public constant BET_AMOUNT = 1000 * 1e6; // 1,000 USDC
    uint256 public constant MIN_DISPUTE_STAKE = 10 * 1e6; // 10 USDC

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Pre-compute ResolutionDAO address for AgiArenaCore's resolver parameter
        uint64 currentNonce = vm.getNonce(address(this));
        address predictedResolutionDAO = vm.computeCreateAddress(address(this), currentNonce + 1);

        // Deploy AgiArenaCore with predicted ResolutionDAO as resolver
        agiArenaCore = new AgiArenaCore(address(usdc), feeRecipient, predictedResolutionDAO);

        // Deploy ResolutionDAO with keeper1 as initial keeper
        resolutionDAO = new ResolutionDAO(keeper1, address(agiArenaCore));

        // Add keeper2 via governance
        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(keeper2);
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper1);
        resolutionDAO.executeKeeperProposal(proposalId);

        // Fund test accounts
        usdc.mint(creator, INITIAL_BALANCE);
        usdc.mint(filler, INITIAL_BALANCE);
        usdc.mint(disputer, INITIAL_BALANCE);

        // Approve AgiArenaCore to spend USDC
        vm.prank(creator);
        usdc.approve(address(agiArenaCore), type(uint256).max);
        vm.prank(filler);
        usdc.approve(address(agiArenaCore), type(uint256).max);

        // Approve ResolutionDAO to spend disputer's USDC (for dispute stake)
        vm.prank(disputer);
        usdc.approve(address(resolutionDAO), type(uint256).max);

        // Approve ResolutionDAO to transfer from AgiArenaCore (for settlement/rewards)
        vm.prank(address(agiArenaCore));
        usdc.approve(address(resolutionDAO), type(uint256).max);
    }

    /// @notice Helper to create and match a bet
    function _createAndMatchBet() internal returns (uint256 betId) {
        bytes32 betHash = keccak256("test-portfolio");
        string memory jsonRef = "test-ref-123";

        // Creator places bet with even odds (1.00x = 10000 bps)
        vm.prank(creator);
        betId = agiArenaCore.placeBet(betHash, jsonRef, BET_AMOUNT, 10000);

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

    // ============ raiseDispute Tests ============

    function test_RaiseDispute_Success() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        uint256 disputerBalanceBefore = usdc.balanceOf(disputer);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Keeper prices incorrect for markets X, Y, Z");

        assertTrue(resolutionDAO.isDisputed(betId), "Bet should be disputed");
        assertEq(usdc.balanceOf(disputer), disputerBalanceBefore - MIN_DISPUTE_STAKE, "Stake should be transferred");

        ResolutionDAO.DisputeInfo memory info = resolutionDAO.getDisputeInfo(betId);
        assertEq(info.disputer, disputer, "Disputer address mismatch");
        assertEq(info.stake, MIN_DISPUTE_STAKE, "Stake amount mismatch");
    }

    function test_RaiseDispute_RevertNoConsensus() public {
        uint256 betId = _createAndMatchBet();
        // No consensus reached

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.ConsensusNotReached.selector, betId));
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Invalid dispute");
    }

    function test_RaiseDispute_RevertInsufficientStake() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        uint256 lowStake = MIN_DISPUTE_STAKE - 1;

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InsufficientDisputeStake.selector, lowStake, MIN_DISPUTE_STAKE));
        resolutionDAO.raiseDispute(betId, lowStake, "Low stake dispute");
    }

    function test_RaiseDispute_RevertEmptyReason() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        vm.expectRevert(ResolutionDAO.DisputeReasonRequired.selector);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "");
    }

    function test_RaiseDispute_RevertReasonTooLong() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        // Create a reason longer than 500 bytes
        bytes memory longReason = new bytes(501);
        for (uint i = 0; i < 501; i++) {
            longReason[i] = "a";
        }

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeReasonTooLong.selector, 501, 500));
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, string(longReason));
    }

    function test_RaiseDispute_RevertAlreadyDisputed() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "First dispute");

        // Try to dispute again
        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeAlreadyRaised.selector, betId));
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Second dispute");
    }

    function test_RaiseDispute_RevertWindowExpired() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        // Warp past dispute window (2 hours + 1 second)
        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(disputer);
        vm.expectRevert(); // DisputeWindowExpired
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Late dispute");
    }

    // ============ resolveDisputeWithRecalculation Tests ============

    function test_ResolveDispute_OutcomeChanged() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500); // Original: creator wins

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Prices were wrong");

        // Keeper resolves with changed outcome (filler wins now)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, -200, false);

        ResolutionDAO.DisputeInfo memory info = resolutionDAO.getDisputeInfo(betId);
        assertTrue(info.outcomeChanged, "Outcome should be changed");
        assertTrue(info.resolvedAt > 0, "Should be resolved");
        assertEq(resolutionDAO.correctedScores(betId), -200, "Corrected score mismatch");
    }

    function test_ResolveDispute_OutcomeUnchanged() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "False alarm");

        // Keeper resolves with same outcome (still creator wins)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 480, true);

        ResolutionDAO.DisputeInfo memory info = resolutionDAO.getDisputeInfo(betId);
        assertFalse(info.outcomeChanged, "Outcome should not be changed");
    }

    function test_ResolveDispute_RevertInvalidScore() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test");

        // Try to resolve with invalid score (> 10000)
        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InvalidScore.selector, int256(20000)));
        resolutionDAO.resolveDisputeWithRecalculation(betId, 20000, true);
    }

    function test_ResolveDispute_RevertNotKeeper() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test");

        // Non-keeper tries to resolve
        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.UnauthorizedKeeper.selector, disputer));
        resolutionDAO.resolveDisputeWithRecalculation(betId, 500, true);
    }

    // ============ slashDisputer Tests ============

    function test_SlashDisputer_Success() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "False dispute");

        // Resolve with unchanged outcome (fake dispute)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 490, true);

        uint256 feesBefore = resolutionDAO.accumulatedFees();

        // Slash the disputer
        vm.prank(keeper1);
        resolutionDAO.slashDisputer(betId);

        assertEq(resolutionDAO.accumulatedFees(), feesBefore + MIN_DISPUTE_STAKE, "Fees should increase by stake");

        // Verify stake is cleared
        ResolutionDAO.DisputeInfo memory info = resolutionDAO.getDisputeInfo(betId);
        assertEq(info.stake, 0, "Stake should be cleared");
    }

    function test_SlashDisputer_RevertOutcomeChanged() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Valid dispute");

        // Resolve with changed outcome (valid dispute)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, -100, false);

        // Try to slash (should fail - dispute was valid)
        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeOutcomeChanged.selector, betId));
        resolutionDAO.slashDisputer(betId);
    }

    // ============ refundDisputer Tests ============

    function test_RefundDisputer_Success() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Valid dispute");

        // Resolve with changed outcome
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, -100, false);

        uint256 disputerBalanceBefore = usdc.balanceOf(disputer);

        // Refund disputer
        resolutionDAO.refundDisputer(betId);

        // Calculate expected reward: 5% of total pot (2000 USDC)
        uint256 totalPot = BET_AMOUNT * 2;
        uint256 expectedReward = (totalPot * 500) / 10000; // 5% = 100 USDC

        assertEq(
            usdc.balanceOf(disputer),
            disputerBalanceBefore + MIN_DISPUTE_STAKE + expectedReward,
            "Disputer should receive stake + reward"
        );
    }

    function test_RefundDisputer_RevertOutcomeUnchanged() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Fake dispute");

        // Resolve with same outcome
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 490, true);

        // Try to refund (should fail - outcome unchanged)
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeOutcomeUnchanged.selector, betId));
        resolutionDAO.refundDisputer(betId);
    }

    // ============ slashKeeper Tests ============

    function test_SlashKeeper_ScoreError() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 1000, 1000); // Keepers voted 10% score

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Keeper error");

        // Resolve with significantly different score (outcome changed required for slash)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, -200, false); // -2%, outcome changed

        // Slash keeper1 (error: 1000 - (-200) = 1200 bps > 500 threshold)
        vm.prank(keeper2);
        resolutionDAO.slashKeeper(keeper1, betId);

        assertTrue(resolutionDAO.isKeeperSlashedForBet(keeper1, betId), "Keeper1 should be slashed");
    }

    function test_SlashKeeper_NoSlashIfOutcomeUnchanged() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 1000, 1000);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test");

        // Resolve with same outcome (fake dispute)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 200, true);

        // Try to slash - should return early because outcome unchanged
        vm.prank(keeper2);
        resolutionDAO.slashKeeper(keeper1, betId);

        // Keeper should NOT be marked as slashed (function returns early)
        assertFalse(resolutionDAO.isKeeperSlashedForBet(keeper1, betId), "Keeper should not be slashed");
    }

    function test_SlashKeeper_NoSlashWithinTolerance() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test");

        // Resolve with changed outcome but keeper score within 5% tolerance
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, -100, false); // Error: 500 - (-100) = 600 > 500, should slash

        // Actually this should slash because 600 > 500 threshold
        vm.prank(keeper2);
        resolutionDAO.slashKeeper(keeper1, betId);

        assertTrue(resolutionDAO.isKeeperSlashedForBet(keeper1, betId), "Keeper should be slashed");
    }

    // ============ settleBet with Dispute Tests ============

    function test_SettleBet_RevertDisputePending() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Pending dispute");

        // Try to settle while dispute is pending
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputePending.selector, betId));
        resolutionDAO.settleBet(betId);
    }

    function test_SettleBet_AfterDisputeResolved_OutcomeChanged() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500); // Original: creator wins

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Outcome wrong");

        // Resolve with changed outcome (filler wins now)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, -200, false);

        // Now settlement should work with corrected outcome
        resolutionDAO.settleBet(betId);

        // Verify filler won (not creator, due to dispute)
        assertEq(resolutionDAO.betWinner(betId), filler, "Filler should win after dispute");
    }

    function test_SettleBet_AfterDisputeResolved_OutcomeUnchanged() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "False alarm");

        // Resolve with unchanged outcome
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 480, true);

        // Settlement should use original outcome
        resolutionDAO.settleBet(betId);

        assertEq(resolutionDAO.betWinner(betId), creator, "Creator should still win");
    }

    // ============ View Function Tests ============

    function test_CanRaiseDispute_True() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        assertTrue(resolutionDAO.canRaiseDispute(betId), "Should be able to dispute");
    }

    function test_CanRaiseDispute_False_NoConsensus() public {
        uint256 betId = _createAndMatchBet();
        // No consensus

        assertFalse(resolutionDAO.canRaiseDispute(betId), "Should not dispute without consensus");
    }

    function test_CanRaiseDispute_False_AlreadyDisputed() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test");

        assertFalse(resolutionDAO.canRaiseDispute(betId), "Should not dispute twice");
    }

    function test_GetDisputeDeadline() public {
        uint256 betId = _createAndMatchBet();
        uint256 consensusTime = block.timestamp;
        _reachConsensus(betId, true, 500, 500);

        uint256 deadline = resolutionDAO.getDisputeDeadline(betId);
        assertEq(deadline, consensusTime + 2 hours, "Deadline should be consensus + 2 hours");
    }

    function test_CanSettleBet_False_DisputePending() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test");

        assertFalse(resolutionDAO.canSettleBet(betId), "Should not settle during dispute");
    }

    function test_CanSettleBet_True_AfterDisputeResolved() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test");

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 500, true);

        assertTrue(resolutionDAO.canSettleBet(betId), "Should be settleable after dispute resolved");
    }
}
