// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/src/Test.sol";
import { ResolutionDAO } from "../src/dao/ResolutionDAO.sol";
import { AgiArenaCore } from "../src/core/AgiArenaCore.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockWIND
/// @notice Mock WIND token for testing (18 decimals)
contract MockWIND is ERC20 {
    constructor() ERC20("WIND Token", "WIND") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title ResolutionDAOTest
/// @notice Comprehensive test suite for ResolutionDAO (Story 8-2)
/// @dev Tests keeper governance, majority-wins resolution, settlement, disputes
contract ResolutionDAOTest is Test {
    ResolutionDAO public resolutionDAO;
    AgiArenaCore public agiArenaCore;
    MockWIND public wind;

    // Test addresses
    address public keeper1 = address(0x1);
    address public keeper2 = address(0x2);
    address public keeper3 = address(0x3);
    address public creator = address(0x4);
    address public filler = address(0x5);
    address public feeRecipient = address(0x6);
    address public disputer = address(0x7);
    address public randomUser = address(0x8);

    // Constants (18 decimals for WIND)
    uint256 public constant INITIAL_BALANCE = 10000 * 1e18;
    uint256 public constant DEFAULT_DEADLINE = 1 days;
    uint256 public constant BET_AMOUNT = 1000 * 1e18;
    uint256 public constant PLATFORM_FEE_BPS = 10;
    uint256 public constant MIN_DISPUTE_STAKE = 10 * 1e18;
    uint256 public constant DISPUTE_WINDOW = 2 hours;

    // Events
    event KeeperProposed(uint256 indexed proposalId, address indexed proposer, address keeper, bool isRemoval);
    event KeeperAdded(address indexed keeper, uint256 proposalId);
    event KeeperRemoved(address indexed keeper, uint256 proposalId);
    event KeeperIPRegistered(address indexed keeper, string ipAddress);
    event ProposalVoteCast(uint256 indexed proposalId, address indexed keeper, bool approve);
    event BetResolutionSubmitted(
        uint256 indexed betId,
        address indexed submitter,
        bytes32 tradesHash,
        uint256 winsCount,
        uint256 validTrades,
        bool creatorWins,
        bool isTie,
        bool isCancelled
    );
    event BetSettled(
        uint256 indexed betId,
        address indexed winner,
        address loser,
        uint256 totalPot,
        uint256 platformFee,
        uint256 winnerPayout
    );
    event BetCancelled(uint256 indexed betId, string reason);
    event WinningsClaimed(uint256 indexed betId, address indexed winner, uint256 amount);
    event DisputeRaised(uint256 indexed betId, address indexed disputer, uint256 stake, string reason);
    event DisputeResolved(uint256 indexed betId, bool outcomeChanged, uint256 correctedWinsCount, uint256 correctedValidTrades);

    function setUp() public {
        // Deploy mock WIND
        wind = new MockWIND();

        // Pre-compute ResolutionDAO address
        uint64 currentNonce = vm.getNonce(address(this));
        address predictedResolutionDAO = vm.computeCreateAddress(address(this), currentNonce + 1);

        // Deploy AgiArenaCore with predicted ResolutionDAO as resolver
        agiArenaCore = new AgiArenaCore(address(wind), feeRecipient, predictedResolutionDAO);

        // Deploy ResolutionDAO with keeper1 as initial keeper
        resolutionDAO = new ResolutionDAO(keeper1, address(agiArenaCore));

        require(address(resolutionDAO) == predictedResolutionDAO, "ResolutionDAO address mismatch");

        // Add keeper2 via governance
        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(keeper2);
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper1);
        resolutionDAO.executeKeeperProposal(proposalId);

        assertTrue(resolutionDAO.isKeeper(keeper2), "keeper2 should be added");

        // Fund test accounts
        wind.mint(creator, INITIAL_BALANCE);
        wind.mint(filler, INITIAL_BALANCE);
        wind.mint(disputer, INITIAL_BALANCE);

        // Approve AgiArenaCore
        vm.prank(creator);
        wind.approve(address(agiArenaCore), type(uint256).max);
        vm.prank(filler);
        wind.approve(address(agiArenaCore), type(uint256).max);

        // Approve ResolutionDAO for disputer
        vm.prank(disputer);
        wind.approve(address(resolutionDAO), type(uint256).max);

        // Approve ResolutionDAO to transfer from AgiArenaCore
        vm.prank(address(agiArenaCore));
        wind.approve(address(resolutionDAO), type(uint256).max);
    }

    // ============ Helper Functions ============

    function _createAndMatchBet() internal returns (uint256 betId) {
        string memory snapshotId = "crypto-2026-01-26-12-00";
        bytes memory positionBitmap = hex"5555555555555555"; // 8 bytes of alternating bits
        string memory jsonRef = "test-ref-123";

        vm.prank(creator);
        betId = agiArenaCore.placeBet(snapshotId, positionBitmap, jsonRef, BET_AMOUNT, 10000, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(filler);
        agiArenaCore.matchBet(betId, BET_AMOUNT);
    }

    function _submitResolution(uint256 betId, bool creatorWins, bool isTie, bool isCancelled) internal {
        bytes32 tradesHash = keccak256(abi.encode("resolved-trades", betId));
        bytes memory packedOutcomes = "";

        uint256 winsCount;
        uint256 validTrades;
        string memory cancelReason = "";

        if (isCancelled) {
            winsCount = 0;
            validTrades = 0;
            cancelReason = "All trades had bad data";
        } else if (isTie) {
            winsCount = 5;
            validTrades = 10;
        } else if (creatorWins) {
            winsCount = 6;
            validTrades = 10;
        } else {
            winsCount = 4;
            validTrades = 10;
        }

        vm.prank(keeper1);
        resolutionDAO.submitResolution(
            betId,
            tradesHash,
            packedOutcomes,
            winsCount,
            validTrades,
            creatorWins,
            isTie,
            isCancelled,
            cancelReason
        );
    }

    function _addKeeper3() internal {
        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(keeper3);
        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper2);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);
        vm.prank(keeper1);
        resolutionDAO.executeKeeperProposal(proposalId);
    }

    // ============ Keeper Governance Tests ============

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
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.UnauthorizedKeeper.selector, randomUser));
        resolutionDAO.proposeKeeper(address(0x99));
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

    function test_ExecuteKeeperProposal_Success() public {
        address newKeeper = address(0x99);

        vm.prank(keeper1);
        uint256 proposalId = resolutionDAO.proposeKeeper(newKeeper);

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

        vm.prank(keeper1);
        resolutionDAO.voteOnKeeperProposal(proposalId, true);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.QuorumNotReached.selector, proposalId));
        resolutionDAO.executeKeeperProposal(proposalId);
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

    // ============ Submit Resolution Tests ============

    function test_SubmitResolution_CreatorWins() public {
        uint256 betId = _createAndMatchBet();

        bytes32 tradesHash = keccak256("trades");
        bytes memory packedOutcomes = "";

        vm.prank(keeper1);
        resolutionDAO.submitResolution(
            betId,
            tradesHash,
            packedOutcomes,
            6,     // winsCount
            10,    // validTrades
            true,  // creatorWins (6/10 > 50%)
            false, // isTie
            false, // isCancelled
            ""
        );

        ResolutionDAO.BetResolution memory resolution = resolutionDAO.getBetResolution(betId);
        assertEq(resolution.winsCount, 6);
        assertEq(resolution.validTrades, 10);
        assertTrue(resolution.creatorWins);
        assertFalse(resolution.isTie);
        assertFalse(resolution.isCancelled);
        assertGt(resolution.resolvedAt, 0);
    }

    function test_SubmitResolution_MatcherWins() public {
        uint256 betId = _createAndMatchBet();

        bytes32 tradesHash = keccak256("trades");

        vm.prank(keeper1);
        resolutionDAO.submitResolution(
            betId,
            tradesHash,
            "",
            3,     // winsCount
            10,    // validTrades
            false, // creatorWins (3/10 < 50%)
            false, // isTie
            false, // isCancelled
            ""
        );

        ResolutionDAO.BetResolution memory resolution = resolutionDAO.getBetResolution(betId);
        assertFalse(resolution.creatorWins);
    }

    function test_SubmitResolution_Tie() public {
        uint256 betId = _createAndMatchBet();

        bytes32 tradesHash = keccak256("trades");

        vm.prank(keeper1);
        resolutionDAO.submitResolution(
            betId,
            tradesHash,
            "",
            5,     // winsCount
            10,    // validTrades
            false, // creatorWins (tie goes to false convention)
            true,  // isTie (5*2 == 10)
            false, // isCancelled
            ""
        );

        ResolutionDAO.BetResolution memory resolution = resolutionDAO.getBetResolution(betId);
        assertTrue(resolution.isTie);
    }

    function test_SubmitResolution_Cancelled() public {
        uint256 betId = _createAndMatchBet();

        bytes32 tradesHash = keccak256("trades");

        vm.prank(keeper1);
        resolutionDAO.submitResolution(
            betId,
            tradesHash,
            "",
            0,     // winsCount
            0,     // validTrades
            false, // creatorWins
            false, // isTie
            true,  // isCancelled
            "All markets had bad data"
        );

        ResolutionDAO.BetResolution memory resolution = resolutionDAO.getBetResolution(betId);
        assertTrue(resolution.isCancelled);
        assertEq(resolution.cancelReason, "All markets had bad data");
    }

    function test_SubmitResolution_Unauthorized() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.UnauthorizedKeeper.selector, randomUser));
        resolutionDAO.submitResolution(betId, bytes32(0), "", 5, 10, true, false, false, "");
    }

    function test_SubmitResolution_AlreadyResolved() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.BetAlreadyResolved.selector, betId));
        resolutionDAO.submitResolution(betId, bytes32(0), "", 5, 10, true, false, false, "");
    }

    function test_SubmitResolution_InvalidTieCondition() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InvalidTieCondition.selector));
        resolutionDAO.submitResolution(
            betId,
            bytes32(0),
            "",
            6,     // winsCount
            10,    // validTrades (6*2 != 10)
            false,
            true,  // isTie claimed but math doesn't match
            false,
            ""
        );
    }

    function test_SubmitResolution_InvalidCreatorWinsCondition() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InvalidCreatorWinsCondition.selector));
        resolutionDAO.submitResolution(
            betId,
            bytes32(0),
            "",
            3,     // winsCount (3/10 = 30%)
            10,    // validTrades
            true,  // creatorWins claimed but 30% < 50%
            false,
            false,
            ""
        );
    }

    function test_SubmitResolution_InvalidCancelledCondition() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InvalidCancelledCondition.selector));
        resolutionDAO.submitResolution(
            betId,
            bytes32(0),
            "",
            5,     // winsCount (should be 0 if cancelled)
            10,    // validTrades (should be 0 if cancelled)
            false,
            false,
            true,  // isCancelled but validTrades != 0
            ""
        );
    }

    function test_SubmitResolution_CancelReasonTooLong() public {
        uint256 betId = _createAndMatchBet();

        // Create a string longer than MAX_REASON_LENGTH (500)
        string memory longReason = new string(501);
        bytes memory reasonBytes = bytes(longReason);
        for (uint256 i = 0; i < 501; i++) {
            reasonBytes[i] = "x";
        }

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeReasonTooLong.selector, 501, 500));
        resolutionDAO.submitResolution(
            betId,
            bytes32(0),
            "",
            0,
            0,
            false,
            false,
            true,  // isCancelled
            string(reasonBytes)
        );
    }

    // ============ Settlement Tests ============

    function test_SettleBet_CreatorWins() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        uint256 creatorBalanceBefore = wind.balanceOf(creator);

        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        assertTrue(resolutionDAO.betSettled(betId));
        assertEq(resolutionDAO.betWinner(betId), creator);

        uint256 totalPot = BET_AMOUNT * 2;
        uint256 platformFee = (totalPot * PLATFORM_FEE_BPS) / 10000;
        uint256 expectedPayout = totalPot - platformFee;
        assertEq(resolutionDAO.winnerPayouts(betId), expectedPayout);
    }

    function test_SettleBet_MatcherWins() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, false, false, false);

        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        assertEq(resolutionDAO.betWinner(betId), filler);
    }

    function test_SettleBet_Tie() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, false, true, false);

        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        assertTrue(resolutionDAO.isTieBet(betId));
        assertGt(resolutionDAO.winnerPayouts(betId), 0);
        assertGt(resolutionDAO.loserPayouts(betId), 0);
    }

    function test_SettleBet_Cancelled() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, false, false, true);

        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        assertTrue(resolutionDAO.isTieBet(betId));
        assertEq(resolutionDAO.winnerPayouts(betId), BET_AMOUNT);
        assertEq(resolutionDAO.loserPayouts(betId), BET_AMOUNT);
    }

    function test_SettleBet_NotResolved() public {
        uint256 betId = _createAndMatchBet();

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.BetNotResolved.selector, betId));
        resolutionDAO.settleBet(betId);
    }

    function test_SettleBet_AlreadySettled() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.prank(randomUser);
        resolutionDAO.settleBet(betId);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.BetAlreadySettled.selector, betId));
        resolutionDAO.settleBet(betId);
    }

    function test_SettleBets_Batch() public {
        uint256 betId1 = _createAndMatchBet();
        uint256 betId2 = _createAndMatchBet();

        _submitResolution(betId1, true, false, false);
        _submitResolution(betId2, false, false, false);

        uint256[] memory betIds = new uint256[](2);
        betIds[0] = betId1;
        betIds[1] = betId2;

        vm.prank(randomUser);
        resolutionDAO.settleBets(betIds);

        assertTrue(resolutionDAO.betSettled(betId1));
        assertTrue(resolutionDAO.betSettled(betId2));
    }

    // ============ Dispute Tests ============

    function test_RaiseDispute_Success() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Incorrect price data");

        assertTrue(resolutionDAO.isDisputed(betId));
        ResolutionDAO.DisputeInfo memory info = resolutionDAO.getDisputeInfo(betId);
        assertEq(info.disputer, disputer);
        assertEq(info.stake, MIN_DISPUTE_STAKE);
    }

    function test_RaiseDispute_InsufficientStake() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        uint256 lowStake = MIN_DISPUTE_STAKE - 1;

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InsufficientDisputeStake.selector, lowStake, MIN_DISPUTE_STAKE));
        resolutionDAO.raiseDispute(betId, lowStake, "Test reason");
    }

    function test_RaiseDispute_TooLate() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        ResolutionDAO.BetResolution memory resolution = resolutionDAO.getBetResolution(betId);
        uint256 deadline = resolution.resolvedAt + DISPUTE_WINDOW;

        vm.prank(disputer);
        vm.expectRevert(
            abi.encodeWithSelector(ResolutionDAO.DisputeWindowExpired.selector, betId, resolution.resolvedAt, deadline)
        );
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test reason");
    }

    function test_RaiseDispute_AlreadyDisputed() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "First dispute");

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeAlreadyRaised.selector, betId));
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Second dispute");
    }

    function test_RaiseDispute_EmptyReason() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeReasonRequired.selector));
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "");
    }

    function test_SettleBet_DisputePending() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test dispute");

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputePending.selector, betId));
        resolutionDAO.settleBet(betId);
    }

    function test_ResolveDispute_Success() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test dispute");

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 4, 10, false);

        ResolutionDAO.DisputeInfo memory info = resolutionDAO.getDisputeInfo(betId);
        assertGt(info.resolvedAt, 0);
        assertTrue(info.outcomeChanged); // Original was creatorWins=true, now false
    }

    function test_ResolveDispute_OutcomeUnchanged() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test dispute");

        // Resolve with same outcome
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 7, 10, true);

        ResolutionDAO.DisputeInfo memory info = resolutionDAO.getDisputeInfo(betId);
        assertFalse(info.outcomeChanged);
    }

    function test_SlashDisputer_Success() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test dispute");

        // Resolve with same outcome (invalid dispute)
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 7, 10, true);

        uint256 feesBefore = resolutionDAO.accumulatedFees();

        vm.prank(keeper1);
        resolutionDAO.slashDisputer(betId);

        assertEq(resolutionDAO.accumulatedFees(), feesBefore + MIN_DISPUTE_STAKE);
    }

    function test_SlashDisputer_OutcomeChanged() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test dispute");

        // Resolve with different outcome
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 4, 10, false);

        vm.prank(keeper1);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeOutcomeChanged.selector, betId));
        resolutionDAO.slashDisputer(betId);
    }

    function test_RefundDisputer_Success() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        uint256 disputerBalanceBefore = wind.balanceOf(disputer);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test dispute");

        // Resolve with different outcome
        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 4, 10, false);

        vm.prank(randomUser);
        resolutionDAO.refundDisputer(betId);

        // Disputer gets stake back + 5% reward
        uint256 totalPot = BET_AMOUNT * 2;
        uint256 reward = (totalPot * 500) / 10000;
        assertEq(wind.balanceOf(disputer), disputerBalanceBefore + reward);
    }

    function test_RefundDisputer_OutcomeUnchanged() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test dispute");

        vm.prank(keeper1);
        resolutionDAO.resolveDisputeWithRecalculation(betId, 7, 10, true);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.DisputeOutcomeUnchanged.selector, betId));
        resolutionDAO.refundDisputer(betId);
    }

    // ============ View Function Tests ============

    function test_GetKeeperCount() public view {
        assertEq(resolutionDAO.getKeeperCount(), 2);
    }

    function test_GetKeeperAtIndex() public view {
        assertEq(resolutionDAO.getKeeperAtIndex(0), keeper1);
        assertEq(resolutionDAO.getKeeperAtIndex(1), keeper2);
    }

    function test_CanSettleBet() public {
        uint256 betId = _createAndMatchBet();

        assertFalse(resolutionDAO.canSettleBet(betId));

        _submitResolution(betId, true, false, false);

        assertTrue(resolutionDAO.canSettleBet(betId));
    }

    function test_CanRaiseDispute() public {
        uint256 betId = _createAndMatchBet();

        assertFalse(resolutionDAO.canRaiseDispute(betId));

        _submitResolution(betId, true, false, false);

        assertTrue(resolutionDAO.canRaiseDispute(betId));

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        assertFalse(resolutionDAO.canRaiseDispute(betId));
    }

    function test_GetDisputeDeadline() public {
        uint256 betId = _createAndMatchBet();

        assertEq(resolutionDAO.getDisputeDeadline(betId), 0);

        _submitResolution(betId, true, false, false);

        ResolutionDAO.BetResolution memory resolution = resolutionDAO.getBetResolution(betId);
        assertEq(resolutionDAO.getDisputeDeadline(betId), resolution.resolvedAt + DISPUTE_WINDOW);
    }

    // ============ Event Tests ============

    function test_BetResolutionSubmitted_Event() public {
        uint256 betId = _createAndMatchBet();

        bytes32 tradesHash = keccak256("trades");

        vm.expectEmit(true, true, false, true);
        emit BetResolutionSubmitted(betId, keeper1, tradesHash, 6, 10, true, false, false);

        vm.prank(keeper1);
        resolutionDAO.submitResolution(betId, tradesHash, "", 6, 10, true, false, false, "");
    }

    function test_DisputeRaised_Event() public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        vm.expectEmit(true, true, false, true);
        emit DisputeRaised(betId, disputer, MIN_DISPUTE_STAKE, "Test dispute");

        vm.prank(disputer);
        resolutionDAO.raiseDispute(betId, MIN_DISPUTE_STAKE, "Test dispute");
    }

    // ============ Fuzz Tests ============

    function testFuzz_SubmitResolution_WinsCount(uint256 winsCount, uint256 validTrades) public {
        validTrades = bound(validTrades, 1, 100);
        winsCount = bound(winsCount, 0, validTrades);

        uint256 betId = _createAndMatchBet();

        bool isTie = (winsCount * 2 == validTrades);
        bool creatorWins = !isTie && (winsCount * 2 > validTrades);

        vm.prank(keeper1);
        resolutionDAO.submitResolution(
            betId,
            keccak256("test"),
            "",
            winsCount,
            validTrades,
            creatorWins,
            isTie,
            false,
            ""
        );

        ResolutionDAO.BetResolution memory resolution = resolutionDAO.getBetResolution(betId);
        assertEq(resolution.winsCount, winsCount);
        assertEq(resolution.validTrades, validTrades);
    }

    function testFuzz_DisputeStake(uint256 stake) public {
        uint256 betId = _createAndMatchBet();
        _submitResolution(betId, true, false, false);

        if (stake < MIN_DISPUTE_STAKE) {
            vm.prank(disputer);
            vm.expectRevert(abi.encodeWithSelector(ResolutionDAO.InsufficientDisputeStake.selector, stake, MIN_DISPUTE_STAKE));
            resolutionDAO.raiseDispute(betId, stake, "Test");
        } else {
            stake = bound(stake, MIN_DISPUTE_STAKE, INITIAL_BALANCE);
            vm.prank(disputer);
            resolutionDAO.raiseDispute(betId, stake, "Test");
            assertTrue(resolutionDAO.isDisputed(betId));
        }
    }
}
