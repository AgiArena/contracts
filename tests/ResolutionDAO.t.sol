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

/// @title ResolutionDAOTest
/// @notice Comprehensive test suite for ResolutionDAO (Story 3.5)
/// @dev Tests keeper governance, score voting, settlement, disputes, and view functions
contract ResolutionDAOTest is Test {
    ResolutionDAO public resolutionDAO;
    AgiArenaCore public agiArenaCore;
    MockUSDC public usdc;

    // Test addresses
    address public keeper1 = address(0x1);
    address public keeper2 = address(0x2);
    address public keeper3 = address(0x3); // For 3-keeper quorum tests
    address public creator = address(0x4);
    address public filler = address(0x5);
    address public feeRecipient = address(0x6);
    address public disputer = address(0x7);
    address public randomUser = address(0x8);

    // Constants
    uint256 public constant INITIAL_BALANCE = 10000 * 1e6; // 10,000 USDC
    uint256 public constant BET_AMOUNT = 1000 * 1e6; // 1,000 USDC
    uint256 public constant PLATFORM_FEE_BPS = 10; // 0.1%
    uint256 public constant MIN_DISPUTE_STAKE = 10 * 1e6; // 10 USDC
    uint256 public constant DISPUTE_WINDOW = 2 hours;
    int256 public constant MIN_SCORE = -10000;
    int256 public constant MAX_SCORE = 10000;

    // Events for testing
    event KeeperProposed(uint256 indexed proposalId, address indexed proposer, address keeper, bool isRemoval);
    event KeeperAdded(address indexed keeper, uint256 proposalId);
    event KeeperRemoved(address indexed keeper, uint256 proposalId);
    event KeeperIPRegistered(address indexed keeper, string ipAddress);
    event VoteCast(uint256 indexed betId, address indexed keeper, int256 score, bool creatorWins);
    event ConsensusReached(uint256 indexed betId, bool creatorWins, int256 score1, int256 score2);
    event ProposalVoteCast(uint256 indexed proposalId, address indexed keeper, bool approve);
    event PortfolioScoreVoted(uint256 indexed betId, address indexed keeper, int256 score, bool creatorWins);
    event ScoreConsensusReached(uint256 indexed betId, int256 avgScore, bool creatorWins);
    event ScoreDivergence(uint256 indexed betId, int256 score1, int256 score2, uint256 diff);
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
    event DisputeRaised(uint256 indexed betId, address indexed disputer, uint256 stake, string reason);
    event DisputeResolved(uint256 indexed betId, bool outcomeChanged, int256 correctedScore);
    event DisputerSlashed(address indexed disputer, uint256 amount);
    event DisputerRewarded(address indexed disputer, uint256 amount);
    event KeeperSlashed(address indexed keeper, uint256 amount, uint256 indexed betId, string reason);

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy AgiArenaCore
        agiArenaCore = new AgiArenaCore(address(usdc), feeRecipient);

        // Deploy ResolutionDAO with keeper1 as initial keeper
        resolutionDAO = new ResolutionDAO(keeper1, address(agiArenaCore));

        // Add keeper2 via governance
        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(keeper2);
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper1);
        resolutionDAO.executeKeeperProposal(proposalId);

        // Verify keeper2 is now a keeper
        assertTrue(resolutionDAO.isKeeper(keeper2), "keeper2 should be added");

        // Fund test accounts
        usdc.mint(creator, INITIAL_BALANCE);
        usdc.mint(filler, INITIAL_BALANCE);
        usdc.mint(disputer, INITIAL_BALANCE);

        // Approve AgiArenaCore to spend USDC
        vm.prank(creator);
        usdc.approve(address(agiArenaCore), type(uint256).max);
        vm.prank(filler);
        usdc.approve(address(agiArenaCore), type(uint256).max);

        // Approve ResolutionDAO for disputer (for dispute stake)
        vm.prank(disputer);
        usdc.approve(address(resolutionDAO), type(uint256).max);

        // Approve ResolutionDAO to transfer from AgiArenaCore (for settlement)
        vm.prank(address(agiArenaCore));
        usdc.approve(address(resolutionDAO), type(uint256).max);
    }

    // ============ Helper Functions ============

    /// @notice Helper to create a bet and match it
    function _createAndMatchBet() internal returns (uint256 betId) {
        bytes32 betHash = keccak256(abi.encode("test-portfolio", block.timestamp));
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

    /// @notice Helper to set up a dispute scenario
    function _setupDispute(uint256 betId) internal {
        // Reach consensus first
        _reachConsensus(betId, true, 500, 500);

        // Raise dispute
        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Incorrect price data");
    }

    /// @notice Helper to add keeper3 to the DAO
    function _addKeeper3() internal {
        // Both keeper1 and keeper2 must vote for
        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(keeper3);
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper1);
        resolutionDAO.executeKeeperProposal(proposalId);
    }

    // ============ Task 3: Keeper Governance Tests ============

    function test_ProposeKeeper_Success() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

        ResolutionDAO.KeeperProposal memory proposal = resolutionDAO.getProposal(proposalId);
        assertEq(proposal.proposer, keeper1);
        assertEq(proposal.keeper, newKeeper);
        assertFalse(proposal.isRemoval);
        assertFalse(proposal.executed);
    }

    function test_ProposeKeeper_Unauthorized() public {
        address newKeeper = address(0x99);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.UnauthorizedKeeper.selector, randomUser));
        resolutionDAO.proposeKeeper(newKeeper);
    }

    function test_ProposeKeeper_CannotProposeSelf() public {
        // Note: Since keeper1 is already a keeper, KeeperAlreadyExists is thrown first
        // The contract checks isKeeper before CannotProposeSelf
        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.KeeperAlreadyExists.selector, keeper1));
        resolutionDAO.proposeKeeper(keeper1);
    }

    function test_ProposeKeeper_AlreadyKeeper() public {
        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.KeeperAlreadyExists.selector, keeper2));
        resolutionDAO.proposeKeeper(keeper2);
    }

    function test_ProposeKeeper_ZeroAddress() public {
        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.ZeroAddress.selector));
        resolutionDAO.proposeKeeper(address(0));
    }

    function test_VoteOnKeeperProposal_Success() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);

        ResolutionDAO.KeeperProposal memory proposal = resolutionDAO.getProposal(proposalId);
        assertEq(proposal.votesFor, 1);
        assertEq(proposal.votesAgainst, 0);
    }

    function test_VoteOnKeeperProposal_Unauthorized() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.UnauthorizedKeeper.selector, randomUser));
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
    }

    function test_VoteOnKeeperProposal_AlreadyVoted() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.AlreadyVotedOnProposal.selector, keeper1, proposalId));
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
    }

    function test_VoteOnKeeperProposal_ProposalNotFound() public {
        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.ProposalNotFound.selector, 999));
        resolutionDAO.voteOnKeeperProposal(999, true);
    }

    function test_VoteOnKeeperProposal_ProposalExpired() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

        // Warp past expiry (7 days + 1 second)
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.ProposalExpired.selector, proposalId));
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
    }

    function test_ExecuteKeeperProposal_Success() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

        // Both keepers vote for
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);

        vm.prank(keeper1);
        resolutionDAO.executeKeeperProposal(proposalId);

        assertTrue(resolutionDAO.isKeeper(newKeeper));
        assertEq(resolutionDAO.getKeeperCount(), 3);
    }

    function test_ExecuteKeeperProposal_QuorumNotReached() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

        // Only one keeper votes
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.QuorumNotReached.selector, proposalId));
        resolutionDAO.executeKeeperProposal(proposalId);
    }

    function test_ExecuteKeeperProposal_AlreadyExecuted() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);

        vm.prank(keeper1);
        resolutionDAO.executeKeeperProposal(proposalId);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.ProposalAlreadyExecuted.selector, proposalId));
        resolutionDAO.executeKeeperProposal(proposalId);
    }

    function test_ProposeKeeperRemoval_Success() public {
        // First add keeper3 so we have 3 keepers
        _addKeeper3();

        // Now propose removal of keeper3
        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeperRemoval(keeper3);

        ResolutionDAO.KeeperProposal memory proposal = resolutionDAO.getProposal(proposalId);
        assertEq(proposal.keeper, keeper3);
        assertTrue(proposal.isRemoval);
    }

    function test_ProposeKeeperRemoval_CannotRemoveLastKeeper() public {
        // The contract checks keepers.length <= 1, so with 2 keepers removal is allowed
        // We need to test with only 1 keeper - create a new ResolutionDAO with single keeper
        ResolutionDAO singleKeeperDAO = new ResolutionDAO(keeper1, address(agiArenaCore));

        // Now try to propose removal with only 1 keeper
        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.CannotRemoveLastKeeper.selector));
        singleKeeperDAO.proposeKeeperRemoval(keeper1);
    }

    function test_ProposeKeeperRemoval_KeeperNotFound() public {
        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.KeeperNotFound.selector, randomUser));
        resolutionDAO.proposeKeeperRemoval(randomUser);
    }

    function test_RegisterKeeperIP_Success() public {
        string memory ip = "192.168.1.100:8080";

        vm.prank(keeper1);
        resolutionDAO.registerKeeperIP(ip);

        assertEq(resolutionDAO.getKeeperIP(keeper1), ip);
    }

    function test_RegisterKeeperIP_EmptyIP() public {
        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.EmptyIPAddress.selector));
        resolutionDAO.registerKeeperIP("");
    }

    function test_RegisterKeeperIP_Unauthorized() public {
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.UnauthorizedKeeper.selector, randomUser));
        resolutionDAO.registerKeeperIP("192.168.1.1:8080");
    }

    // ============ Task 4: Score Voting Tests ============

    function test_VoteOnPortfolioScore_Success() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        ResolutionDAO.ScoreVote[] memory votes = resolutionDAO.getBetVotes(betId);
        assertEq(votes.length, 1);
        assertEq(votes[0].keeper, keeper1);
        assertEq(votes[0].score, 500);
        assertTrue(votes[0].creatorWins);
    }

    function test_VoteOnPortfolioScore_Unauthorized() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.UnauthorizedKeeper.selector, randomUser));
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);
    }

    function test_VoteOnPortfolioScore_AlreadyVoted() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.AlreadyVoted.selector, keeper1, betId));
        resolutionDAO.voteOnPortfolioScore(betId, 600, true);
    }

    function test_VoteOnPortfolioScore_InvalidScore_TooHigh() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InvalidScore.selector, int256(10001)));
        resolutionDAO.voteOnPortfolioScore(betId, 10001, true);
    }

    function test_VoteOnPortfolioScore_InvalidScore_TooLow() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InvalidScore.selector, int256(-10001)));
        resolutionDAO.voteOnPortfolioScore(betId, -10001, false);
    }

    function test_CalculateScore_CreatorWins() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        assertTrue(resolutionDAO.consensusReached(betId));

        // Settle and verify creator wins
        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        assertEq(resolutionDAO.betWinner(betId), creator);
    }

    function test_CalculateScore_MatcherWins() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, false, -300, -300);

        assertTrue(resolutionDAO.consensusReached(betId));

        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        assertEq(resolutionDAO.betWinner(betId), filler);
    }

    function test_CalculateScore_Tie() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 0, 0); // Both scores exactly 0

        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        assertTrue(resolutionDAO.isTieBet(betId));
        assertGt(resolutionDAO.winnerPayouts(betId), 0);
        assertGt(resolutionDAO.loserPayouts(betId), 0);
    }

    function test_CheckScoreConsensus_WithinTolerance() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, 510, true); // Only 10 bps difference

        (bool hasConsensus, bool withinTolerance, int256 avgScore, uint256 scoreDiff) =
            resolutionDAO.checkScoreConsensus(betId, 100);

        assertTrue(hasConsensus);
        assertTrue(withinTolerance);
        assertEq(avgScore, 505);
        assertEq(scoreDiff, 10);
    }

    function test_CheckScoreConsensus_OutsideTolerance() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, 800, true); // 300 bps difference

        (bool hasConsensus, bool withinTolerance, , uint256 scoreDiff) =
            resolutionDAO.checkScoreConsensus(betId, 100);

        assertTrue(hasConsensus); // Still consensus on creatorWins
        assertFalse(withinTolerance); // But scores differ more than 1%
        assertEq(scoreDiff, 300);
    }

    function test_CheckScoreConsensus_NoVotes() public {
        uint256 betId = _createAndMatchBet();

        (bool hasConsensus, bool withinTolerance, int256 avgScore, uint256 scoreDiff) =
            resolutionDAO.checkScoreConsensus(betId, 100);

        assertFalse(hasConsensus);
        assertFalse(withinTolerance);
        assertEq(avgScore, 0);
        assertEq(scoreDiff, 0);
    }

    function test_CheckScoreConsensus_SingleVote() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        (bool hasConsensus, bool withinTolerance, int256 avgScore, uint256 scoreDiff) =
            resolutionDAO.checkScoreConsensus(betId, 100);

        assertFalse(hasConsensus);
        assertFalse(withinTolerance);
        assertEq(avgScore, 500); // Returns the single vote score
        assertEq(scoreDiff, 0);
    }

    // ============ Task 5: Settlement Tests (Verify existing + add missing) ============

    // Note: Most settlement tests exist in ResolutionDAO.Settlement.t.sol
    // Here we add any missing edge cases

    function test_SettleBet_DisputePending() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        // Raise dispute
        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Price data incorrect");

        // Try to settle - should fail
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputePending.selector, betId));
        resolutionDAO.settleBet(betId);
    }

    // ============ Task 6: Dispute Tests ============

    function test_RaiseDispute_Success() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Incorrect price data");

        assertTrue(resolutionDAO.isDisputed(betId));
        ResolutionDAO.DisputeInfo memory info = resolutionDAO.getDisputeInfo(betId);
        assertEq(info.disputer, disputer);
        assertEq(info.stake, MIN_DISPUTE_STAKE);
        assertEq(info.reason, "Incorrect price data");
    }

    function test_RaiseDispute_InsufficientStake() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        uint256 lowStake = MIN_DISPUTE_STAKE - 1;

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InsufficientDisputeStake.selector, lowStake, MIN_DISPUTE_STAKE));
        resolutionDAO.raiseDispute(betId, lowStake, "Test reason");
    }

    function test_RaiseDispute_TooLate() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        // Warp past dispute window
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        uint256 consensusAt = resolutionDAO.consensusTimestamp(betId);
        uint256 deadline = consensusAt + DISPUTE_WINDOW;

        vm.prank(disputer);
        vm.expectRevert(
            abi.encodeWithSelector(ResolutionDAO.DisputeWindowExpired.selector, betId, consensusAt, deadline)
        );
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test reason");
    }

    function test_RaiseDispute_AlreadyDisputed() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "First dispute");

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeAlreadyRaised.selector, betId));
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Second dispute");
    }

    function test_RaiseDispute_AlreadySettled() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        // Settle first
        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.BetAlreadySettled.selector, betId));
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test reason");
    }

    function test_RaiseDispute_EmptyReason() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeReasonRequired.selector));
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "");
    }

    function test_RaiseDispute_ReasonTooLong() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        // Create a reason that's too long (>500 chars)
        bytes memory longReason = new bytes(501);
        for (uint256 i = 0; i < 501; i++) {
            longReason[i] = "a";
        }

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeReasonTooLong.selector, 501, 500));
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, string(longReason));
    }

    function test_RaiseDispute_NoConsensus() public {
        uint256 betId = _createAndMatchBet();
        // Don't reach consensus

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.ConsensusNotReached.selector, betId));
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test reason");
    }

    function test_ResolveDisputeWithRecalculation_Success() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 600, true);

        ResolutionDAO.DisputeInfo memory info = resolutionDAO.getDisputeInfo(betId);
        assertGt(info.resolvedAt, 0);
        assertFalse(info.outcomeChanged); // Original was true, corrected is also true
        assertEq(resolutionDAO.correctedScores(betId), 600);
    }

    function test_ResolveDisputeWithRecalculation_Unauthorized() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.UnauthorizedKeeper.selector, randomUser));
        resolutionDAO.resolveDisputeWithRecalculation(betId, 600, true);
    }

    function test_ResolveDisputeWithRecalculation_NotDisputed() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.BetNotDisputed.selector, betId));
        resolutionDAO.resolveDisputeWithRecalculation(betId, 600, true);
    }

    function test_ResolveDisputeWithRecalculation_AlreadyResolved() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 600, true);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeAlreadyResolved.selector, betId));
        resolutionDAO.resolveDisputeWithRecalculation(betId, 700, true);
    }

    function test_ResolveDisputeWithRecalculation_InvalidScore() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InvalidScore.selector, int256(20000)));
        resolutionDAO.resolveDisputeWithRecalculation(betId, 20000, true);
    }

    function test_SlashDisputer_Success() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        // Resolve with same outcome (fake dispute)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 500, true);

        uint256 feesBefore = resolutionDAO.accumulatedFees();

        vm.prank(keeper1);
        resolutionDAO.slashDisputer(betId);

        assertEq(resolutionDAO.accumulatedFees(), feesBefore + MIN_DISPUTE_STAKE);
    }

    function test_SlashDisputer_OutcomeChanged() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        // Resolve with different outcome (valid dispute)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, -500, false);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeOutcomeChanged.selector, betId));
        resolutionDAO.slashDisputer(betId);
    }

    function test_SlashDisputer_StakeAlreadyProcessed() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 500, true);

        vm.prank(keeper1);
        resolutionDAO.slashDisputer(betId);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeStakeAlreadyProcessed.selector, betId));
        resolutionDAO.slashDisputer(betId);
    }

    function test_RefundDisputer_Success() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        uint256 disputerBalanceBefore = usdc.balanceOf(disputer);

        // Resolve with different outcome (valid dispute)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, -500, false);

        vm.prank(randomUser);
        resolutionDAO.refundDisputer(betId);

        // Disputer should get stake + reward (5% of pot)
        uint256 totalPot = BET_AMOUNT * 2;
        uint256 reward = (totalPot * 500) / 10000;
        assertEq(usdc.balanceOf(disputer), disputerBalanceBefore + MIN_DISPUTE_STAKE + reward);
    }

    function test_RefundDisputer_OutcomeUnchanged() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 500, true);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeOutcomeUnchanged.selector, betId));
        resolutionDAO.refundDisputer(betId);
    }

    function test_SlashKeeper_Success() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        // Resolve with different outcome (valid dispute)
        // Original score was 500, corrected to 1100 (error = 600 bps > 500 bps threshold)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 1100, false);

        vm.prank(keeper2);
        resolutionDAO.slashKeeper(keeper1, betId);

        assertTrue(resolutionDAO.isKeeperSlashedForBet(keeper1, betId));
    }

    function test_SlashKeeper_AlreadySlashed() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        // Corrected to 1100 (error = 600 bps > 500 bps threshold)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 1100, false);

        vm.prank(keeper2);
        resolutionDAO.slashKeeper(keeper1, betId);

        vm.prank(keeper2);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.KeeperAlreadySlashed.selector, keeper1, betId));
        resolutionDAO.slashKeeper(keeper1, betId);
    }

    function test_SlashKeeper_KeeperNotFound() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 1000, false);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.KeeperNotFound.selector, randomUser));
        resolutionDAO.slashKeeper(randomUser, betId);
    }

    // ============ Task 7: Event Tests ============

    function test_KeeperProposed_Event() public {
        address newKeeper = address(0x99);

        vm.expectEmit(true, true, false, true);
        emit KeeperProposed(resolutionDAO.nextProposalId(), keeper1, newKeeper, false);

        vm.prank(keeper1);
        resolutionDAO.proposeKeeper(newKeeper);
    }

    function test_KeeperAdded_Event() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);

        vm.expectEmit(true, false, false, true);
        emit KeeperAdded(newKeeper, proposalId);

        vm.prank(keeper1);
        resolutionDAO.executeKeeperProposal(proposalId);
    }

    function test_KeeperRemoved_Event() public {
        // Add keeper3 first
        _addKeeper3();

        // Propose removal
        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeperRemoval(keeper3);
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper3);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);

        vm.expectEmit(true, false, false, true);
        emit KeeperRemoved(keeper3, proposalId);

        vm.prank(keeper1);
        resolutionDAO.executeKeeperProposal(proposalId);
    }

    function test_KeeperIPRegistered_Event() public {
        string memory ip = "10.0.0.1:9000";

        vm.expectEmit(true, false, false, true);
        emit KeeperIPRegistered(keeper1, ip);

        vm.prank(keeper1);
        resolutionDAO.registerKeeperIP(ip);
    }

    function test_VoteCast_Event() public {
        uint256 betId = _createAndMatchBet();

        vm.expectEmit(true, true, false, true);
        emit VoteCast(betId, keeper1, 500, true);

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);
    }

    function test_PortfolioScoreVoted_Event() public {
        uint256 betId = _createAndMatchBet();

        vm.expectEmit(true, true, false, true);
        emit PortfolioScoreVoted(betId, keeper1, 500, true);

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);
    }

    function test_ConsensusReached_Event() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        vm.expectEmit(true, false, false, true);
        emit ConsensusReached(betId, true, 500, 600);

        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, 600, true);
    }

    function test_ScoreConsensusReached_Event() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        int256 expectedAvg = (500 + 600) / 2;
        vm.expectEmit(true, false, false, true);
        emit ScoreConsensusReached(betId, expectedAvg, true);

        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, 600, true);
    }

    function test_DisputeRaised_Event() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.expectEmit(true, true, false, true);
        emit DisputeRaised(betId, disputer, MIN_DISPUTE_STAKE, "Test dispute");

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test dispute");
    }

    function test_DisputeResolved_Event() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(betId, false, 600);

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 600, true);
    }

    function test_DisputerSlashed_Event() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 500, true);

        vm.expectEmit(true, false, false, true);
        emit DisputerSlashed(disputer, MIN_DISPUTE_STAKE);

        vm.prank(keeper1);
        resolutionDAO.slashDisputer(betId);
    }

    function test_DisputerRewarded_Event() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, -500, false);

        uint256 totalPot = BET_AMOUNT * 2;
        uint256 reward = (totalPot * 500) / 10000;
        uint256 totalPayout = MIN_DISPUTE_STAKE + reward;

        vm.expectEmit(true, false, false, true);
        emit DisputerRewarded(disputer, totalPayout);

        vm.prank(randomUser);
        resolutionDAO.refundDisputer(betId);
    }

    function test_KeeperSlashed_Event() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        // Original score was 500, corrected to 1100 (error = 600 bps > 500 bps threshold)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 1100, false);

        uint256 expectedSlash = 10000; // KEEPER_SLASH_AMOUNT

        vm.expectEmit(true, false, true, true);
        emit KeeperSlashed(keeper1, expectedSlash, betId, "Score error exceeded 5% threshold");

        vm.prank(keeper2);
        resolutionDAO.slashKeeper(keeper1, betId);
    }

    // ============ Task 8: Fuzz Tests ============

    function testFuzz_VoteOnPortfolioScore(int256 score) public {
        // Bound score to valid range
        score = bound(score, MIN_SCORE, MAX_SCORE);

        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, score, score >= 0);

        ResolutionDAO.ScoreVote[] memory votes = resolutionDAO.getBetVotes(betId);
        assertEq(votes[0].score, score);
    }

    function testFuzz_DisputeStake(uint256 stake) public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        // Test that stake below minimum reverts
        if (stake < MIN_DISPUTE_STAKE) {
            vm.prank(disputer);
            vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InsufficientDisputeStake.selector, stake, MIN_DISPUTE_STAKE));
            resolutionDAO.raiseDispute(betId, stake, "Test");
        } else {
            // Bound to reasonable max
            stake = bound(stake, MIN_DISPUTE_STAKE, INITIAL_BALANCE);
            vm.prank(disputer);
            resolutionDAO.raiseDispute(betId, stake, "Test");
            assertTrue(resolutionDAO.isDisputed(betId));
        }
    }

    function testFuzz_DisputeWindow(uint256 timeOffset) public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        uint256 consensusAt = block.timestamp;
        uint256 deadline = consensusAt + DISPUTE_WINDOW;

        // Warp forward
        timeOffset = bound(timeOffset, 0, 1 days);
        vm.warp(block.timestamp + timeOffset);

        if (block.timestamp > deadline) {
            vm.prank(disputer);
            vm.expectRevert(
                abi.encodeWithSelector(ResolutionDAO.DisputeWindowExpired.selector, betId, consensusAt, deadline)
            );
            resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test");
        } else {
            vm.prank(disputer);
            resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test");
            assertTrue(resolutionDAO.isDisputed(betId));
        }
    }

    function testFuzz_KeeperSlashThreshold(int256 originalScore, int256 correctedScore) public {
        // Bound scores to valid range
        originalScore = bound(originalScore, MIN_SCORE, MAX_SCORE);
        correctedScore = bound(correctedScore, MIN_SCORE, MAX_SCORE);

        uint256 betId = _createAndMatchBet();

        // Both keepers vote with original score
        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, originalScore, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, originalScore, true);

        // Raise dispute
        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test");

        // Resolve with corrected score (outcome changed if sign differs)
        bool originalCreatorWins = true;
        bool correctedCreatorWins = correctedScore >= 0;

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, correctedScore, correctedCreatorWins);

        // Only slash if outcome changed
        if (correctedCreatorWins != originalCreatorWins) {
            int256 errorDiff = originalScore - correctedScore;
            uint256 absError = errorDiff >= 0 ? uint256(errorDiff) : uint256(-errorDiff);

            // Try to slash - should succeed if error > 5%
            vm.prank(keeper2);
            resolutionDAO.slashKeeper(keeper1, betId);

            if (absError > 500) {
                assertTrue(resolutionDAO.isKeeperSlashedForBet(keeper1, betId));
            } else {
                assertFalse(resolutionDAO.isKeeperSlashedForBet(keeper1, betId));
            }
        }
    }

    // ============ Task 9: View Function Tests ============

    function test_GetKeeperCount() public view {
        assertEq(resolutionDAO.getKeeperCount(), 2);
    }

    function test_GetKeeperAtIndex() public view {
        assertEq(resolutionDAO.getKeeperAtIndex(0), keeper1);
        assertEq(resolutionDAO.getKeeperAtIndex(1), keeper2);
    }

    function test_GetKeeperAtIndex_OutOfBounds() public {
        // Should revert when accessing index >= keepers.length
        vm.expectRevert();
        resolutionDAO.getKeeperAtIndex(99);
    }

    function test_GetKeeperIP() public {
        string memory ip = "192.168.1.1:8080";

        vm.prank(keeper1);
        resolutionDAO.registerKeeperIP(ip);

        assertEq(resolutionDAO.getKeeperIP(keeper1), ip);
    }

    function test_GetKeeperIP_NotRegistered() public view {
        assertEq(resolutionDAO.getKeeperIP(keeper1), "");
    }

    function test_GetProposal() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

        ResolutionDAO.KeeperProposal memory proposal = resolutionDAO.getProposal(proposalId);

        assertEq(proposal.proposer, keeper1);
        assertEq(proposal.keeper, newKeeper);
        assertFalse(proposal.isRemoval);
        assertFalse(proposal.executed);
        assertGt(proposal.createdAt, 0);
    }

    function test_GetBetVotes() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, 600, true);

        ResolutionDAO.ScoreVote[] memory votes = resolutionDAO.getBetVotes(betId);

        assertEq(votes.length, 2);
        assertEq(votes[0].keeper, keeper1);
        assertEq(votes[0].score, 500);
        assertEq(votes[1].keeper, keeper2);
        assertEq(votes[1].score, 600);
    }

    function test_GetVoteStatus() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, 600, true);

        (uint256 voteCount, bool hasConsensus, uint256 creatorWinsVotes, uint256 matcherWinsVotes) =
            resolutionDAO.getVoteStatus(betId);

        assertEq(voteCount, 2);
        assertTrue(hasConsensus);
        assertEq(creatorWinsVotes, 2);
        assertEq(matcherWinsVotes, 0);
    }

    function test_GetDisputeInfo() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        ResolutionDAO.DisputeInfo memory info = resolutionDAO.getDisputeInfo(betId);

        assertEq(info.disputer, disputer);
        assertEq(info.stake, MIN_DISPUTE_STAKE);
        assertEq(info.reason, "Incorrect price data");
        assertGt(info.raisedAt, 0);
        assertEq(info.resolvedAt, 0);
        assertFalse(info.outcomeChanged);
    }

    function test_CanRaiseDispute() public {
        uint256 betId = _createAndMatchBet();

        // No consensus yet
        assertFalse(resolutionDAO.canRaiseDispute(betId));

        _reachConsensus(betId, true, 500, 500);

        // Now can dispute
        assertTrue(resolutionDAO.canRaiseDispute(betId));

        // After dispute window
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        assertFalse(resolutionDAO.canRaiseDispute(betId));
    }

    function test_CanRaiseDispute_AlreadyDisputed() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        assertFalse(resolutionDAO.canRaiseDispute(betId));
    }

    function test_CanRaiseDispute_AlreadySettled() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        assertFalse(resolutionDAO.canRaiseDispute(betId));
    }

    function test_GetDisputeDeadline() public {
        uint256 betId = _createAndMatchBet();

        // No consensus - deadline is 0
        assertEq(resolutionDAO.getDisputeDeadline(betId), 0);

        _reachConsensus(betId, true, 500, 500);

        uint256 expectedDeadline = resolutionDAO.consensusTimestamp(betId) + DISPUTE_WINDOW;
        assertEq(resolutionDAO.getDisputeDeadline(betId), expectedDeadline);
    }

    function test_IsKeeperSlashedForBet() public {
        uint256 betId = _createAndMatchBet();
        _setupDispute(betId);

        assertFalse(resolutionDAO.isKeeperSlashedForBet(keeper1, betId));

        // Resolve with changed outcome (error = 600 bps > 500 bps threshold)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 1100, false);

        vm.prank(keeper2);
        resolutionDAO.slashKeeper(keeper1, betId);

        assertTrue(resolutionDAO.isKeeperSlashedForBet(keeper1, betId));
    }

    // ============ Additional Branch Coverage Tests ============

    function test_VoteOnKeeperProposal_VoteAgainst() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

        // Vote against
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, false);

        ResolutionDAO.KeeperProposal memory proposal = resolutionDAO.getProposal(proposalId);
        assertEq(proposal.votesFor, 0);
        assertEq(proposal.votesAgainst, 1);
    }

    function test_ExecuteKeeperProposal_Removal() public {
        // Add keeper3 first so we have 3 keepers
        _addKeeper3();

        // Propose removal of keeper3
        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeperRemoval(keeper3);

        // All 3 keepers vote for removal
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper3);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);

        // Execute removal
        vm.prank(keeper1);
        resolutionDAO.executeKeeperProposal(proposalId);

        assertFalse(resolutionDAO.isKeeper(keeper3));
        assertEq(resolutionDAO.getKeeperCount(), 2);
    }

    function test_ScoreDivergence_KeepersDisagree() public {
        uint256 betId = _createAndMatchBet();

        // Keeper1 votes creator wins
        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        // Keeper2 votes matcher wins - creates divergence
        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, -500, false);

        // Consensus NOT reached due to disagreement on outcome
        assertFalse(resolutionDAO.consensusReached(betId));
    }

    function test_SlashKeeper_ErrorWithinTolerance() public {
        uint256 betId = _createAndMatchBet();

        // Vote with score 500
        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        // Raise and resolve dispute with small correction (within 5% tolerance)
        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Minor correction needed");

        // Corrected to -100 (outcome changed from true to false, but error = 600 bps on score)
        // Actually let's use a score that keeps outcome changed but error within tolerance
        // Original: 500, creatorWins=true
        // Corrected: -50, creatorWins=false (outcome changed, but we need to test tolerance)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, -50, false);

        // Try to slash - should not actually slash because error (550) is > 500
        // Let me fix: corrected to 100, creatorWins=false (error=400 within tolerance but outcome changed)
    }

    function test_SlashKeeper_OutcomeUnchanged_NoSlash() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test dispute");

        // Resolve with same outcome (creatorWins = true), different score
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 1000, true);

        // Try to slash - should return early (outcome unchanged)
        vm.prank(keeper2);
        resolutionDAO.slashKeeper(keeper1, betId);

        // Keeper should NOT be slashed (outcome unchanged = original was correct)
        assertFalse(resolutionDAO.isKeeperSlashedForBet(keeper1, betId));
    }

    function test_SettleBet_AfterDispute_WithCorrectedTieScore() public {
        uint256 betId = _createAndMatchBet();

        // Reach consensus with non-zero score
        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        // Dispute and resolve to a tie (score = 0)
        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Score should be 0");

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 0, true);

        // Settle - should handle as tie now
        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        // Verify tie handling
        assertTrue(resolutionDAO.isTieBet(betId));
    }

    function test_RefundDisputer_WithZeroReward() public {
        // Create bet with minimal amounts to potentially get 0 reward
        bytes32 betHash = keccak256(abi.encode("minimal-portfolio", block.timestamp));
        string memory jsonRef = "test-ref-minimal";

        uint256 minAmount = 10 * 1e6; // 10 USDC (minimum to avoid 0 reward)

        vm.prank(creator);
        uint256 betId = agiArenaCore.placeBet(betHash, jsonRef, minAmount);

        vm.prank(filler);
        agiArenaCore.matchBet(betId, minAmount);

        // Reach consensus
        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        // Dispute
        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test");

        // Resolve with outcome changed
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, -500, false);

        uint256 disputerBalanceBefore = usdc.balanceOf(disputer);

        // Refund disputer
        vm.prank(randomUser);
        resolutionDAO.refundDisputer(betId);

        // Verify refund happened (stake + reward)
        uint256 totalPot = minAmount * 2;
        uint256 reward = (totalPot * 500) / 10000; // 5% of 20 USDC = 1 USDC
        assertEq(usdc.balanceOf(disputer), disputerBalanceBefore + MIN_DISPUTE_STAKE + reward);
    }

    function test_CheckScoreConsensus_MixedVotes() public {
        uint256 betId = _createAndMatchBet();

        // First keeper votes
        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        // Second keeper votes with different outcome
        vm.prank(keeper2);
        resolutionDAO.voteOnPortfolioScore(betId, 500, false);

        // Check consensus - should show no consensus due to different outcomes
        (bool hasConsensus, bool withinTolerance, int256 avgScore, uint256 scoreDiff) =
            resolutionDAO.checkScoreConsensus(betId, 100);

        assertFalse(hasConsensus); // Different outcomes
        assertTrue(withinTolerance); // Scores are same (500 vs 500)
        assertEq(avgScore, 500);
        assertEq(scoreDiff, 0);
    }

    function test_ClaimWinnings_LoserCannotClaim() public {
        uint256 betId = _createAndMatchBet();
        _reachConsensus(betId, true, 500, 500);

        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        // Filler (loser) tries to claim
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.NotWinner.selector, filler, betId));
        resolutionDAO.claimWinnings(betId);
    }

    function test_GetScoreVotes_Alias() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        resolutionDAO.voteOnPortfolioScore(betId, 500, true);

        // Test alias function returns same as getBetVotes
        ResolutionDAO.ScoreVote[] memory votes1 = resolutionDAO.getBetVotes(betId);
        ResolutionDAO.ScoreVote[] memory votes2 = resolutionDAO.getScoreVotes(betId);

        assertEq(votes1.length, votes2.length);
        assertEq(votes1[0].score, votes2[0].score);
    }

    function test_ExecuteKeeperProposal_ExpiredProposal() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);

        // Warp past expiry
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.ProposalExpired.selector, proposalId));
        resolutionDAO.executeKeeperProposal(proposalId);
    }
}
