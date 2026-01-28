// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/src/Test.sol";
import { AgiArenaCore } from "../src/core/AgiArenaCore.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Simple ERC20 mock for testing (6 decimals like real USDC)
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title AgiArenaCoreTest
/// @notice Unit tests for AgiArenaCore smart contract with asymmetric odds support
contract AgiArenaCoreTest is Test {
    AgiArenaCore public core;
    MockUSDC public usdc;

    address public feeRecipient = address(0xFEE);
    address public resolver = address(0xBE5);
    address public trader1 = address(0x1);
    address public trader2 = address(0x2);
    address public trader3 = address(0x3);

    uint256 constant INITIAL_BALANCE = 10_000e6; // 10k USDC (6 decimals)
    string constant TEST_SNAPSHOT_ID = "crypto-2026-01-26-12-30";
    bytes constant TEST_POSITION_BITMAP = hex"5555555555555555"; // 8 bytes of alternating bits
    string constant TEST_JSON_REF = "agent-1-bet-123";
    // Pre-computed tradesHash = keccak256(TEST_SNAPSHOT_ID + TEST_POSITION_BITMAP)
    bytes32 immutable TEST_TRADES_HASH;

    // Odds constants
    uint32 constant ODDS_EVEN = 10000; // 1.00x (even odds)
    uint32 constant ODDS_2X = 20000;   // 2.00x
    uint32 constant ODDS_3X = 30000;   // 3.00x
    uint32 constant ODDS_05X = 5000;   // 0.50x
    uint32 constant ODDS_15X = 15000;  // 1.50x

    // Default deadline: 1 day from now (used in tests)
    uint256 constant DEFAULT_DEADLINE = 1 days;

    constructor() {
        // Compute TEST_TRADES_HASH in constructor (immutable)
        TEST_TRADES_HASH = keccak256(abi.encodePacked(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP));
    }

    event BetPlaced(
        uint256 indexed betId,
        address indexed creator,
        bytes32 tradesHash,
        string snapshotId,
        string jsonStorageRef,
        uint256 creatorStake,
        uint256 requiredMatch,
        uint32 oddsBps,
        uint256 resolutionDeadline
    );
    event BetMatched(uint256 indexed betId, address indexed filler, uint256 fillAmount, uint256 remaining);
    event BetCancelled(uint256 indexed betId, address indexed creator, uint256 refundAmount);
    event BetSettled(uint256 indexed betId, address indexed winner, uint256 payout, bool creatorWon);

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy AgiArenaCore with resolver
        core = new AgiArenaCore(address(usdc), feeRecipient, resolver);

        // Fund test accounts
        usdc.mint(trader1, INITIAL_BALANCE);
        usdc.mint(trader2, INITIAL_BALANCE);
        usdc.mint(trader3, INITIAL_BALANCE);

        // Approve core contract for all traders
        vm.prank(trader1);
        usdc.approve(address(core), type(uint256).max);

        vm.prank(trader2);
        usdc.approve(address(core), type(uint256).max);

        vm.prank(trader3);
        usdc.approve(address(core), type(uint256).max);
    }

    // ============ Constructor Tests ============

    function test_Constructor() public view {
        assertEq(address(core.COLLATERAL_TOKEN()), address(usdc));
        assertEq(core.FEE_RECIPIENT(), feeRecipient);
        assertEq(core.RESOLVER(), resolver);
        assertEq(core.PLATFORM_FEE_BPS(), 10);
        assertEq(core.ODDS_EVEN(), 10000);
        assertEq(core.MAX_MATCHERS(), 100);
        assertEq(core.nextBetId(), 0);
    }

    function test_Constructor_ZeroAddressUSDC() public {
        vm.expectRevert(AgiArenaCore.ZeroAddress.selector);
        new AgiArenaCore(address(0), feeRecipient, resolver);
    }

    function test_Constructor_ZeroAddressFeeRecipient() public {
        vm.expectRevert(AgiArenaCore.ZeroAddress.selector);
        new AgiArenaCore(address(usdc), address(0), resolver);
    }

    function test_Constructor_ZeroAddressResolver() public {
        vm.expectRevert(AgiArenaCore.ZeroAddress.selector);
        new AgiArenaCore(address(usdc), feeRecipient, address(0));
    }

    // ============ placeBet Tests with Odds ============

    function test_PlacePortfolioBet_EvenOdds() public {
        uint256 creatorStake = 1000e6; // 1k USDC

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Verify bet ID
        assertEq(betId, 0);
        assertEq(core.nextBetId(), 1);

        // Verify bet state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.tradesHash, TEST_TRADES_HASH);
        assertEq(bet.jsonStorageRef, TEST_JSON_REF);
        assertEq(bet.creatorStake, creatorStake);
        assertEq(bet.requiredMatch, creatorStake); // 1.00x = equal stakes
        assertEq(bet.matchedAmount, 0);
        assertEq(bet.oddsBps, ODDS_EVEN);
        assertEq(bet.creator, trader1);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.Pending));

        // Verify USDC transfer
        assertEq(usdc.balanceOf(trader1), INITIAL_BALANCE - creatorStake);
        assertEq(usdc.balanceOf(address(core)), creatorStake);
    }

    function test_PlacePortfolioBet_2xOdds() public {
        uint256 creatorStake = 1000e6;
        // At 2.00x odds: requiredMatch = (1000 * 10000) / 20000 = 500
        uint256 expectedRequiredMatch = 500e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.creatorStake, creatorStake);
        assertEq(bet.requiredMatch, expectedRequiredMatch);
        assertEq(bet.oddsBps, ODDS_2X);
    }

    function test_PlacePortfolioBet_05xOdds() public {
        uint256 creatorStake = 1000e6;
        // At 0.50x odds: requiredMatch = (1000 * 10000) / 5000 = 2000
        uint256 expectedRequiredMatch = 2000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_05X, block.timestamp + DEFAULT_DEADLINE);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.creatorStake, creatorStake);
        assertEq(bet.requiredMatch, expectedRequiredMatch);
        assertEq(bet.oddsBps, ODDS_05X);
    }

    function test_PlacePortfolioBet_15xOdds() public {
        uint256 creatorStake = 1000e6;
        // At 1.50x odds: requiredMatch = (1000 * 10000) / 15000 = 666.666... = 666
        uint256 expectedRequiredMatch = 666666666; // ~666.67 USDC (truncated)

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_15X, block.timestamp + DEFAULT_DEADLINE);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.creatorStake, creatorStake);
        assertEq(bet.requiredMatch, expectedRequiredMatch);
        assertEq(bet.oddsBps, ODDS_15X);
    }

    function test_PlacePortfolioBet_EmitsEventWithOdds() public {
        uint256 creatorStake = 500e6;
        uint256 expectedRequiredMatch = 250e6; // 2.00x odds
        uint256 deadline = block.timestamp + DEFAULT_DEADLINE;

        vm.expectEmit(true, true, false, true);
        emit BetPlaced(0, trader1, TEST_TRADES_HASH, TEST_SNAPSHOT_ID, TEST_JSON_REF, creatorStake, expectedRequiredMatch, ODDS_2X, deadline);

        vm.prank(trader1);
        core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, deadline);
    }

    function test_PlacePortfolioBet_InvalidOdds_Zero() public {
        vm.prank(trader1);
        vm.expectRevert(AgiArenaCore.InvalidOdds.selector);
        core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, 1000e6, 0, block.timestamp + DEFAULT_DEADLINE);
    }

    function test_PlacePortfolioBet_ExtremeOdds_1bps() public {
        // 1 bps = 0.01% = 0.0001x - extreme but allowed (no min limit)
        uint256 creatorStake = 1000e6;
        // requiredMatch = (1000 * 10000) / 1 = 10_000_000 USDC
        uint256 expectedRequiredMatch = 10_000_000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, 1, block.timestamp + DEFAULT_DEADLINE);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.requiredMatch, expectedRequiredMatch);
        assertEq(bet.oddsBps, 1);
    }

    function test_PlacePortfolioBet_ExtremeOdds_1000000bps() public {
        // 1_000_000 bps = 100x odds (no max limit)
        uint256 creatorStake = 1000e6;
        // requiredMatch = (1000 * 10000) / 1_000_000 = 10 USDC
        uint256 expectedRequiredMatch = 10e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, 1_000_000, block.timestamp + DEFAULT_DEADLINE);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.requiredMatch, expectedRequiredMatch);
        assertEq(bet.oddsBps, 1_000_000);
    }

    function test_PlacePortfolioBet_RequiredMatchCantBeZero() public {
        // If odds are very high and stake is small, requiredMatch could round to 0
        // This should revert with ZeroAmount
        // With 1 wei stake and max uint32 bps: (1 * 10000) / 4294967295 = 0 (truncated)
        vm.prank(trader1);
        vm.expectRevert(AgiArenaCore.ZeroAmount.selector);
        core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, 1, type(uint32).max, block.timestamp + DEFAULT_DEADLINE);
    }

    function test_PlacePortfolioBet_InsufficientBalance() public {
        uint256 creatorStake = INITIAL_BALANCE + 1; // More than balance

        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.InsufficientBalance.selector, creatorStake, INITIAL_BALANCE));
        core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);
    }

    function test_PlacePortfolioBet_ZeroAmount() public {
        vm.prank(trader1);
        vm.expectRevert(AgiArenaCore.ZeroAmount.selector);
        core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, 0, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);
    }

    function test_PlacePortfolioBet_InvalidBitmap() public {
        vm.prank(trader1);
        vm.expectRevert(AgiArenaCore.InvalidBetHash.selector);
        // Empty bitmap should fail
        core.placeBet(TEST_SNAPSHOT_ID, hex"", TEST_JSON_REF, 1000e6, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);
    }

    function test_PlacePortfolioBet_InvalidSnapshotId() public {
        vm.prank(trader1);
        vm.expectRevert(AgiArenaCore.InvalidSnapshotId.selector);
        // Empty snapshot ID should fail
        core.placeBet("", TEST_POSITION_BITMAP, TEST_JSON_REF, 1000e6, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);
    }

    function test_PlaceMultipleBets() public {
        vm.startPrank(trader1);

        uint256 bet1 = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, "ref-1", 100e6, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);
        uint256 bet2 = core.placeBet("snapshot-2", hex"AAAA", "ref-2", 200e6, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);
        uint256 bet3 = core.placeBet("snapshot-3", hex"BBBB", "ref-3", 300e6, ODDS_05X, block.timestamp + DEFAULT_DEADLINE);

        vm.stopPrank();

        assertEq(bet1, 0);
        assertEq(bet2, 1);
        assertEq(bet3, 2);
        assertEq(core.nextBetId(), 3);
    }

    // ============ matchBet Tests with Odds ============

    function test_MatchPortfolioBet_FullFill_EvenOdds() public {
        uint256 creatorStake = 1000e6;

        // Trader1 places bet with even odds
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Trader2 fully matches (requiredMatch == creatorStake at 1.00x)
        vm.prank(trader2);
        core.matchBet(betId, creatorStake);

        // Verify bet state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.matchedAmount, creatorStake);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));

        // Verify USDC transfers
        assertEq(usdc.balanceOf(trader2), INITIAL_BALANCE - creatorStake);
        assertEq(usdc.balanceOf(address(core)), creatorStake * 2); // Both traders' funds
    }

    function test_MatchPortfolioBet_FullFill_2xOdds() public {
        uint256 creatorStake = 1000e6;
        uint256 requiredMatch = 500e6; // At 2.00x odds

        // Trader1 places bet with 2.00x odds
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        // Trader2 fully matches (only needs 500 USDC)
        vm.prank(trader2);
        core.matchBet(betId, requiredMatch);

        // Verify bet state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.matchedAmount, requiredMatch);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));

        // Verify USDC in contract: 1000 from creator + 500 from matcher = 1500
        assertEq(usdc.balanceOf(address(core)), creatorStake + requiredMatch);
    }

    function test_MatchPortfolioBet_PartialFill_2xOdds() public {
        uint256 creatorStake = 1000e6;
        uint256 requiredMatch = 500e6; // At 2.00x odds
        uint256 fillAmount = 200e6;

        // Trader1 places bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        // Trader2 partially matches
        vm.prank(trader2);
        core.matchBet(betId, fillAmount);

        // Verify bet state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.matchedAmount, fillAmount);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.PartiallyMatched));

        // Verify remaining is based on requiredMatch
        assertEq(bet.requiredMatch - bet.matchedAmount, 300e6);
    }

    function test_MatchPortfolioBet_MultipleFills_WithOdds() public {
        uint256 creatorStake = 1000e6;
        uint256 requiredMatch = 500e6; // At 2.00x odds

        // Trader1 places bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        // Multiple partial fills
        vm.prank(trader2);
        core.matchBet(betId, 150e6);

        vm.prank(trader3);
        core.matchBet(betId, 250e6);

        vm.prank(trader2);
        core.matchBet(betId, 100e6);

        // Verify bet state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.matchedAmount, requiredMatch);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));

        // Verify fill records
        assertEq(core.getBetFillCount(betId), 3);
    }

    function test_MatchPortfolioBet_EmitsEvent() public {
        uint256 creatorStake = 1000e6;
        uint256 fillAmount = 200e6;
        uint256 remainingAfterFill = 300e6; // requiredMatch(500) - fill(200) = 300

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        vm.expectEmit(true, true, false, true);
        emit BetMatched(betId, trader2, fillAmount, remainingAfterFill);

        vm.prank(trader2);
        core.matchBet(betId, fillAmount);
    }

    function test_MatchPortfolioBet_FillExceedsRemaining_WithOdds() public {
        uint256 creatorStake = 1000e6;
        uint256 requiredMatch = 500e6; // At 2.00x odds

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        // Try to fill more than requiredMatch
        vm.prank(trader2);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.FillExceedsRemaining.selector, requiredMatch + 1, requiredMatch));
        core.matchBet(betId, requiredMatch + 1);
    }

    function test_MatchPortfolioBet_BetNotFound() public {
        vm.prank(trader2);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotFound.selector, 999));
        core.matchBet(999, 100e6);
    }

    function test_MatchPortfolioBet_ZeroAmount() public {
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, 1000e6, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        vm.expectRevert(AgiArenaCore.ZeroAmount.selector);
        core.matchBet(betId, 0);
    }

    function test_MatchPortfolioBet_AlreadyFullyMatched() public {
        uint256 creatorStake = 1000e6;
        uint256 requiredMatch = 500e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        // Fully match
        vm.prank(trader2);
        core.matchBet(betId, requiredMatch);

        // Try to match again
        vm.prank(trader3);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotPending.selector, betId));
        core.matchBet(betId, 100e6);
    }

    function test_MatchPortfolioBet_FillerInsufficientBalance() public {
        uint256 creatorStake = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Drain trader2's balance
        vm.prank(trader2);
        usdc.transfer(address(0xdead), INITIAL_BALANCE);

        // Try to match with no balance
        vm.prank(trader2);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.InsufficientBalance.selector, creatorStake, 0));
        core.matchBet(betId, creatorStake);
    }

    // ============ cancelBet Tests with Odds ============

    function test_CancelPortfolioBet_EvenOdds() public {
        uint256 creatorStake = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        uint256 balanceBeforeCancel = usdc.balanceOf(trader1);

        vm.prank(trader1);
        core.cancelBet(betId);

        // Verify bet state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.Cancelled));

        // Verify USDC refund
        assertEq(usdc.balanceOf(trader1), balanceBeforeCancel + creatorStake);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_CancelPortfolioBet_2xOdds() public {
        uint256 creatorStake = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        uint256 balanceBeforeCancel = usdc.balanceOf(trader1);

        vm.prank(trader1);
        core.cancelBet(betId);

        // Full refund of creatorStake
        assertEq(usdc.balanceOf(trader1), balanceBeforeCancel + creatorStake);
    }

    function test_CancelPortfolioBet_PartiallyMatched_WithOdds() public {
        uint256 creatorStake = 1000e6;
        uint256 requiredMatch = 500e6; // 2.00x odds
        uint256 matchedAmount = 200e6;

        // Expected refund: creator gets back proportional to unmatched
        // unmatched = 500 - 200 = 300 (60% unmatched)
        // refund = 1000 * 300 / 500 = 600
        uint256 expectedRefund = 600e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        // Partially match
        vm.prank(trader2);
        core.matchBet(betId, matchedAmount);

        uint256 balanceBeforeCancel = usdc.balanceOf(trader1);

        // Cancel unfilled portion
        vm.prank(trader1);
        core.cancelBet(betId);

        // Verify bet state - should be FullyMatched (closed to new matches)
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));
        assertEq(bet.matchedAmount, matchedAmount); // Still has the matched amount

        // Verify refund of proportional unfilled portion
        assertEq(usdc.balanceOf(trader1), balanceBeforeCancel + expectedRefund);

        // Contract should hold: creator's matched stake (400) + matcher's fill (200) = 600
        assertEq(usdc.balanceOf(address(core)), 600e6);
    }

    function test_CancelPortfolioBet_EmitsEvent() public {
        uint256 creatorStake = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        vm.expectEmit(true, true, false, true);
        emit BetCancelled(betId, trader1, creatorStake);

        vm.prank(trader1);
        core.cancelBet(betId);
    }

    function test_CancelPortfolioBet_AlreadyMatched() public {
        uint256 creatorStake = 1000e6;
        uint256 requiredMatch = 500e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        // Fully match
        vm.prank(trader2);
        core.matchBet(betId, requiredMatch);

        // Try to cancel - should fail because bet is fully matched
        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotPending.selector, betId));
        core.cancelBet(betId);
    }

    function test_CancelPortfolioBet_Unauthorized() public {
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, 1000e6, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Try to cancel as different user
        vm.prank(trader2);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.Unauthorized.selector, trader2));
        core.cancelBet(betId);
    }

    function test_CancelPortfolioBet_BetNotFound() public {
        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotFound.selector, 999));
        core.cancelBet(999);
    }

    function test_CancelPortfolioBet_FullyUnmatched_WithOdds() public {
        // Verify that cancelling an unmatched bet at non-even odds returns EXACT creatorStake
        uint256 creatorStake = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        uint256 balanceBeforeCancel = usdc.balanceOf(trader1);

        vm.prank(trader1);
        core.cancelBet(betId);

        // EXACT refund - no rounding loss allowed
        assertEq(usdc.balanceOf(trader1), balanceBeforeCancel + creatorStake, "Full refund expected");
        assertEq(usdc.balanceOf(address(core)), 0, "Contract should be empty");
    }

    function test_CancelPortfolioBet_3xOdds() public {
        // Test 3.00x odds cancellation
        uint256 creatorStake = 900e6; // Use value divisible by 3 for clean math
        // requiredMatch = 900 * 10000 / 30000 = 300

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_3X, block.timestamp + DEFAULT_DEADLINE);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.requiredMatch, 300e6);

        uint256 balanceBeforeCancel = usdc.balanceOf(trader1);

        vm.prank(trader1);
        core.cancelBet(betId);

        assertEq(usdc.balanceOf(trader1), balanceBeforeCancel + creatorStake);
    }

    // ============ Self-Matching Prevention Tests ============

    function test_MatchPortfolioBet_CannotSelfMatch() public {
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, 1000e6, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Creator trying to match their own bet should fail
        vm.prank(trader1);
        vm.expectRevert(AgiArenaCore.CannotMatchOwnBet.selector);
        core.matchBet(betId, 500e6);
    }

    // ============ getBetState Tests ============

    function test_GetBetState_NotFound() public {
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotFound.selector, 999));
        core.getBetState(999);
    }

    // ============ computeTradesHash Tests ============

    function test_ComputeTradesHash_MatchesOnChainComputation() public {
        // Verify the pure function matches what placeBet stores
        bytes32 expectedHash = core.computeTradesHash(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP);
        assertEq(expectedHash, TEST_TRADES_HASH);

        // Place bet and verify stored hash matches
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, 1000e6, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.tradesHash, expectedHash);
    }

    function test_ComputeTradesHash_DifferentInputsProduceDifferentHashes() public view {
        bytes32 hash1 = core.computeTradesHash("snap-a", hex"01");
        bytes32 hash2 = core.computeTradesHash("snap-b", hex"01");
        bytes32 hash3 = core.computeTradesHash("snap-a", hex"02");

        assertTrue(hash1 != hash2, "Different snapshots should produce different hashes");
        assertTrue(hash1 != hash3, "Different bitmaps should produce different hashes");
        assertTrue(hash2 != hash3, "All hashes should be unique");
    }

    // ============ Backwards Compatibility Tests (AC: 6) ============

    function test_BackwardsCompatibility_EvenOdds_BehavesLike1to1() public {
        uint256 creatorStake = 1000e6;

        // Place bet with even odds (1.00x)
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Verify requiredMatch equals creatorStake
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.requiredMatch, bet.creatorStake, "At 1.00x, requiredMatch should equal creatorStake");

        // Match with equal amount
        vm.prank(trader2);
        core.matchBet(betId, creatorStake);

        bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));

        // Total in contract should be 2x creator stake
        assertEq(usdc.balanceOf(address(core)), creatorStake * 2);
    }

    function test_BackwardsCompatibility_MatchingLogicUnchangedAtEvenOdds() public {
        uint256 creatorStake = 1000e6;

        // Place bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Partial fill
        vm.prank(trader2);
        core.matchBet(betId, 300e6);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.matchedAmount, 300e6);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.PartiallyMatched));
        assertEq(bet.requiredMatch - bet.matchedAmount, 700e6); // Remaining

        // Complete fill
        vm.prank(trader3);
        core.matchBet(betId, 700e6);

        bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));
    }

    // ============ Fuzz Tests ============

    function testFuzz_PlaceBet_WithOdds(uint256 creatorStake, uint32 oddsBps) public {
        // Bound creatorStake to reasonable values
        creatorStake = bound(creatorStake, 1e6, INITIAL_BALANCE);
        // Bound odds to non-zero and reasonable range
        oddsBps = uint32(bound(oddsBps, 1, 1_000_000)); // 0.01% to 100x

        // Calculate expected requiredMatch
        uint256 expectedRequiredMatch = (creatorStake * ODDS_EVEN) / oddsBps;

        // Skip if requiredMatch would be 0 (dust bet prevention)
        if (expectedRequiredMatch == 0) return;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, oddsBps, block.timestamp + DEFAULT_DEADLINE);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.creatorStake, creatorStake);
        assertEq(bet.requiredMatch, expectedRequiredMatch);
        assertEq(bet.oddsBps, oddsBps);
        assertEq(usdc.balanceOf(address(core)), creatorStake);
    }

    function testFuzz_MatchBet_WithOdds(uint256 creatorStake, uint32 oddsBps, uint256 fillAmount) public {
        // Bound creatorStake
        creatorStake = bound(creatorStake, 1e6, INITIAL_BALANCE);
        // Bound odds
        oddsBps = uint32(bound(oddsBps, 1, 100_000)); // Max 10x to avoid huge requiredMatch

        uint256 requiredMatch = (creatorStake * ODDS_EVEN) / oddsBps;
        if (requiredMatch == 0) return;

        // Bound fillAmount to valid range
        fillAmount = bound(fillAmount, 1, requiredMatch);
        if (fillAmount > INITIAL_BALANCE) return; // Skip if filler can't afford

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, oddsBps, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, fillAmount);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.matchedAmount, fillAmount);
    }

    function testFuzz_OddsBps(uint32 oddsBps) public {
        // Test any non-zero odds value
        vm.assume(oddsBps > 0);

        uint256 creatorStake = 1000e6;
        uint256 requiredMatch = (creatorStake * ODDS_EVEN) / oddsBps;

        // Skip if requiredMatch is 0
        vm.assume(requiredMatch > 0);

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, oddsBps, block.timestamp + DEFAULT_DEADLINE);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.oddsBps, oddsBps);
        assertEq(bet.requiredMatch, requiredMatch);
    }

    function testFuzz_CancelBet_ProportionalRefund(uint256 creatorStake, uint32 oddsBps, uint256 fillPercent) public {
        // Bound inputs
        creatorStake = bound(creatorStake, 1e6, INITIAL_BALANCE);
        oddsBps = uint32(bound(oddsBps, 100, 100_000)); // 0.01x to 10x odds
        fillPercent = bound(fillPercent, 1, 99); // 1-99% filled (not 0% or 100%)

        uint256 requiredMatch = (creatorStake * ODDS_EVEN) / oddsBps;
        if (requiredMatch == 0) return;

        // Calculate fill amount based on percentage
        uint256 fillAmount = (requiredMatch * fillPercent) / 100;
        if (fillAmount == 0 || fillAmount >= requiredMatch) return;
        if (fillAmount > INITIAL_BALANCE) return;

        // Place bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, oddsBps, block.timestamp + DEFAULT_DEADLINE);

        // Partially match
        vm.prank(trader2);
        core.matchBet(betId, fillAmount);

        uint256 balanceBefore = usdc.balanceOf(trader1);
        uint256 contractBalanceBefore = usdc.balanceOf(address(core));

        // Cancel remaining
        vm.prank(trader1);
        core.cancelBet(betId);

        // Calculate expected refund proportionally
        uint256 unmatchedRatio = requiredMatch - fillAmount;
        uint256 expectedRefund = (creatorStake * unmatchedRatio) / requiredMatch;

        // Verify refund
        uint256 actualRefund = usdc.balanceOf(trader1) - balanceBefore;
        assertEq(actualRefund, expectedRefund, "Proportional refund mismatch");

        // Verify contract balance decreased by refund
        assertEq(usdc.balanceOf(address(core)), contractBalanceBefore - expectedRefund);
    }

    function testFuzz_CancelBet_FullyUnmatched(uint256 creatorStake, uint32 oddsBps) public {
        // Bound inputs
        creatorStake = bound(creatorStake, 1e6, INITIAL_BALANCE);
        oddsBps = uint32(bound(oddsBps, 1, 1_000_000)); // Very wide range

        uint256 requiredMatch = (creatorStake * ODDS_EVEN) / oddsBps;
        if (requiredMatch == 0) return;

        // Place bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, oddsBps, block.timestamp + DEFAULT_DEADLINE);

        uint256 balanceBefore = usdc.balanceOf(trader1);

        // Cancel without any fills
        vm.prank(trader1);
        core.cancelBet(betId);

        // MUST get exact creatorStake back - no rounding loss allowed
        assertEq(usdc.balanceOf(trader1), balanceBefore + creatorStake, "Exact refund required");
        assertEq(usdc.balanceOf(address(core)), 0, "Contract should be empty");
    }

    // ============ Odds Calculation Tests ============

    function test_OddsCalculation_Examples() public {
        // Test the examples from the architecture doc
        uint256 creatorStake = 100e6; // $100

        // 2.00x odds: requiredMatch = $50
        vm.prank(trader1);
        uint256 bet1 = core.placeBet("snap1", hex"01", "ref1", creatorStake, 20000, block.timestamp + DEFAULT_DEADLINE);
        assertEq(core.getBetState(bet1).requiredMatch, 50e6);

        // 1.50x odds: requiredMatch = ~$66.67
        vm.prank(trader1);
        uint256 bet2 = core.placeBet("snap2", hex"02", "ref2", creatorStake, 15000, block.timestamp + DEFAULT_DEADLINE);
        assertEq(core.getBetState(bet2).requiredMatch, 66666666); // ~66.67

        // 1.00x odds: requiredMatch = $100
        vm.prank(trader1);
        uint256 bet3 = core.placeBet("snap3", hex"03", "ref3", creatorStake, 10000, block.timestamp + DEFAULT_DEADLINE);
        assertEq(core.getBetState(bet3).requiredMatch, 100e6);

        // 0.50x odds: requiredMatch = $200
        vm.prank(trader1);
        uint256 bet4 = core.placeBet("snap4", hex"04", "ref4", creatorStake, 5000, block.timestamp + DEFAULT_DEADLINE);
        assertEq(core.getBetState(bet4).requiredMatch, 200e6);
    }

    // ============ Integration Tests ============

    function test_FullBettingFlow_WithOdds() public {
        uint256 creatorStake = 1000e6;
        uint32 odds = ODDS_2X; // 2.00x
        uint256 requiredMatch = 500e6;

        // Step 1: Place bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, odds, block.timestamp + DEFAULT_DEADLINE);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.Pending));
        assertEq(bet.requiredMatch, requiredMatch);

        // Step 2: First partial fill (30% of requiredMatch)
        vm.prank(trader2);
        core.matchBet(betId, 150e6);

        bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.PartiallyMatched));
        assertEq(bet.matchedAmount, 150e6);

        // Step 3: Second partial fill (50% of requiredMatch)
        vm.prank(trader3);
        core.matchBet(betId, 250e6);

        bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.PartiallyMatched));
        assertEq(bet.matchedAmount, 400e6);

        // Step 4: Final fill (20% of requiredMatch) - completes the bet
        vm.prank(trader2);
        core.matchBet(betId, 100e6);

        bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));
        assertEq(bet.matchedAmount, 500e6);

        // Verify USDC balances
        assertEq(usdc.balanceOf(trader1), INITIAL_BALANCE - creatorStake);
        assertEq(usdc.balanceOf(trader2), INITIAL_BALANCE - 250e6); // 150 + 100
        assertEq(usdc.balanceOf(trader3), INITIAL_BALANCE - 250e6);
        assertEq(usdc.balanceOf(address(core)), creatorStake + requiredMatch); // 1500 total
    }

    function test_BetStateTransitions_WithOdds() public {
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, 1000e6, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);
        // requiredMatch = 500e6

        // Initial: Pending
        assertEq(uint256(core.getBetState(betId).status), uint256(AgiArenaCore.BetStatus.Pending));

        // After partial: PartiallyMatched
        vm.prank(trader2);
        core.matchBet(betId, 100e6);
        assertEq(uint256(core.getBetState(betId).status), uint256(AgiArenaCore.BetStatus.PartiallyMatched));

        // After full: FullyMatched
        vm.prank(trader2);
        core.matchBet(betId, 400e6);
        assertEq(uint256(core.getBetState(betId).status), uint256(AgiArenaCore.BetStatus.FullyMatched));
    }

    // ============ settleBet Tests ============

    function test_SettleBet_CreatorWins_EvenOdds() public {
        uint256 creatorStake = 1000e6;

        // Place and fully match bet at even odds
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, creatorStake);

        // Track balances before settlement
        uint256 trader1BalanceBefore = usdc.balanceOf(trader1);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        // Resolver settles - creator wins
        vm.prank(resolver);
        core.settleBet(betId, true);

        // Verify bet status
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.Settled));

        // Calculate expected payout
        uint256 totalPot = creatorStake * 2; // 2000e6
        uint256 platformFee = (totalPot * 10) / 10000; // 0.1% = 0.2e6
        uint256 expectedPayout = totalPot - platformFee; // 1999.8e6

        // Verify transfers
        assertEq(usdc.balanceOf(trader1), trader1BalanceBefore + expectedPayout);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + platformFee);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_SettleBet_CreatorWins_2xOdds() public {
        uint256 creatorStake = 1000e6;
        uint256 requiredMatch = 500e6; // 2.00x odds

        // Place and fully match bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, requiredMatch);

        uint256 trader1BalanceBefore = usdc.balanceOf(trader1);

        // Settle - creator wins
        vm.prank(resolver);
        core.settleBet(betId, true);

        // Total pot = 1000 + 500 = 1500
        // Fee = 1500 * 0.001 = 1.5
        // Payout = 1500 - 1.5 = 1498.5
        uint256 totalPot = creatorStake + requiredMatch;
        uint256 platformFee = (totalPot * 10) / 10000;
        uint256 expectedPayout = totalPot - platformFee;

        assertEq(usdc.balanceOf(trader1), trader1BalanceBefore + expectedPayout);
    }

    function test_SettleBet_MatcherWins_SingleMatcher() public {
        uint256 creatorStake = 1000e6;

        // Place and match at even odds
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, creatorStake);

        uint256 trader2BalanceBefore = usdc.balanceOf(trader2);

        // Settle - matcher wins
        vm.prank(resolver);
        core.settleBet(betId, false);

        uint256 totalPot = creatorStake * 2;
        uint256 platformFee = (totalPot * 10) / 10000;
        uint256 expectedPayout = totalPot - platformFee;

        // Single matcher gets entire payout
        assertEq(usdc.balanceOf(trader2), trader2BalanceBefore + expectedPayout);
    }

    function test_SettleBet_MatcherWins_MultipleMatchers_Proportional() public {
        uint256 creatorStake = 1000e6;
        uint256 requiredMatch = 500e6; // 2.00x odds

        // Place bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_2X, block.timestamp + DEFAULT_DEADLINE);

        // Multiple matchers - trader2 fills 300, trader3 fills 200
        vm.prank(trader2);
        core.matchBet(betId, 300e6); // 60% of requiredMatch

        vm.prank(trader3);
        core.matchBet(betId, 200e6); // 40% of requiredMatch

        uint256 trader2BalanceBefore = usdc.balanceOf(trader2);
        uint256 trader3BalanceBefore = usdc.balanceOf(trader3);

        // Settle - matchers win
        vm.prank(resolver);
        core.settleBet(betId, false);

        // Total pot = 1000 + 500 = 1500
        // Fee = 1.5e6
        // Distributable = 1498.5e6
        uint256 totalPot = creatorStake + requiredMatch;
        uint256 platformFee = (totalPot * 10) / 10000;
        uint256 distributable = totalPot - platformFee;

        // Trader2 share: 300/500 * 1498.5 = 899.1 (truncated)
        uint256 trader2ExpectedShare = (distributable * 300e6) / requiredMatch;
        // Trader3 gets remainder: 1498.5 - 899.1 = 599.4
        uint256 trader3ExpectedShare = distributable - trader2ExpectedShare;

        assertEq(usdc.balanceOf(trader2), trader2BalanceBefore + trader2ExpectedShare, "Trader2 share wrong");
        assertEq(usdc.balanceOf(trader3), trader3BalanceBefore + trader3ExpectedShare, "Trader3 share wrong");
    }

    function test_SettleBet_MatcherWins_ThreeMatchers() public {
        uint256 creatorStake = 1000e6;

        // Place bet at even odds
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Three matchers with different fill amounts
        address trader4 = address(0x4);
        usdc.mint(trader4, INITIAL_BALANCE);
        vm.prank(trader4);
        usdc.approve(address(core), type(uint256).max);

        vm.prank(trader2);
        core.matchBet(betId, 500e6); // 50%

        vm.prank(trader3);
        core.matchBet(betId, 300e6); // 30%

        vm.prank(trader4);
        core.matchBet(betId, 200e6); // 20%

        uint256 trader2Before = usdc.balanceOf(trader2);
        uint256 trader3Before = usdc.balanceOf(trader3);
        uint256 trader4Before = usdc.balanceOf(trader4);

        // Settle
        vm.prank(resolver);
        core.settleBet(betId, false);

        uint256 totalPot = 2000e6;
        uint256 platformFee = (totalPot * 10) / 10000; // 2e6 / 10 = 0.2e6
        uint256 distributable = totalPot - platformFee;

        // Proportional shares
        uint256 trader2Share = (distributable * 500e6) / 1000e6;
        uint256 trader3Share = (distributable * 300e6) / 1000e6;
        uint256 trader4Share = distributable - trader2Share - trader3Share; // Remainder

        assertEq(usdc.balanceOf(trader2), trader2Before + trader2Share);
        assertEq(usdc.balanceOf(trader3), trader3Before + trader3Share);
        assertEq(usdc.balanceOf(trader4), trader4Before + trader4Share);
    }

    function test_SettleBet_EmitsEvent_CreatorWins() public {
        uint256 creatorStake = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, creatorStake);

        uint256 totalPot = creatorStake * 2;
        uint256 platformFee = (totalPot * 10) / 10000;
        uint256 expectedPayout = totalPot - platformFee;

        vm.expectEmit(true, true, false, true);
        emit BetSettled(betId, trader1, expectedPayout, true);

        vm.prank(resolver);
        core.settleBet(betId, true);
    }

    function test_SettleBet_EmitsEvent_MatcherWins() public {
        uint256 creatorStake = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, creatorStake);

        uint256 totalPot = creatorStake * 2;
        uint256 platformFee = (totalPot * 10) / 10000;
        uint256 expectedPayout = totalPot - platformFee;

        vm.expectEmit(true, true, false, true);
        emit BetSettled(betId, address(0), expectedPayout, false);

        vm.prank(resolver);
        core.settleBet(betId, false);
    }

    function test_SettleBet_NotResolver() public {
        uint256 creatorStake = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, creatorStake);

        // Non-resolver tries to settle
        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.NotResolver.selector, trader1));
        core.settleBet(betId, true);
    }

    function test_SettleBet_BetNotFound() public {
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotFound.selector, 999));
        core.settleBet(999, true);
    }

    function test_SettleBet_BetNotFullyMatched_Pending() public {
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, 1000e6, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Bet is pending, not fully matched
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotFullyMatched.selector, betId));
        core.settleBet(betId, true);
    }

    function test_SettleBet_BetNotFullyMatched_PartiallyMatched() public {
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, 1000e6, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, 500e6); // Only partially matched

        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotFullyMatched.selector, betId));
        core.settleBet(betId, true);
    }

    function test_SettleBet_AlreadySettled() public {
        uint256 creatorStake = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, creatorStake);

        // First settlement
        vm.prank(resolver);
        core.settleBet(betId, true);

        // Second attempt should fail with BetAlreadySettled
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetAlreadySettled.selector, betId));
        core.settleBet(betId, true);
    }

    function test_SettleBet_SameMatcherMultipleFills() public {
        uint256 creatorStake = 1000e6;

        // Place bet at even odds
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Same matcher fills multiple times
        vm.prank(trader2);
        core.matchBet(betId, 400e6); // First fill

        vm.prank(trader2);
        core.matchBet(betId, 350e6); // Second fill

        vm.prank(trader2);
        core.matchBet(betId, 250e6); // Third fill (totals 1000e6)

        uint256 trader2Before = usdc.balanceOf(trader2);

        // Settle - matchers win (same address gets all three payments)
        vm.prank(resolver);
        core.settleBet(betId, false);

        uint256 totalPot = 2000e6;
        uint256 platformFee = (totalPot * 10) / 10000;
        uint256 payout = totalPot - platformFee;

        // Trader2 should get entire payout (three separate transfers but same recipient)
        assertEq(usdc.balanceOf(trader2), trader2Before + payout);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_SettleBet_AsymmetricOdds_0_5x_MatcherWins() public {
        // 0.50x odds: creator stakes $50, matcher stakes $100
        uint256 creatorStake = 50e6;
        uint256 requiredMatch = 100e6; // 0.50x odds

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_05X, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, requiredMatch);

        uint256 trader2Before = usdc.balanceOf(trader2);

        vm.prank(resolver);
        core.settleBet(betId, false);

        // Total pot = 150e6, fee = 0.15e6, payout = 149.85e6
        uint256 totalPot = 150e6;
        uint256 platformFee = (totalPot * 10) / 10000; // 15000 = 0.015e6
        uint256 payout = totalPot - platformFee;

        assertEq(usdc.balanceOf(trader2), trader2Before + payout);
    }

    function test_SettleBet_AsymmetricOdds_3x_CreatorWins() public {
        // 3.00x odds: creator stakes $900, matcher stakes $300
        uint256 creatorStake = 900e6;
        uint256 requiredMatch = 300e6; // 3.00x odds

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_3X, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, requiredMatch);

        uint256 trader1Before = usdc.balanceOf(trader1);

        vm.prank(resolver);
        core.settleBet(betId, true);

        // Total pot = 1200e6, fee = 1.2e6, payout = 1198.8e6
        uint256 totalPot = 1200e6;
        uint256 platformFee = (totalPot * 10) / 10000;
        uint256 payout = totalPot - platformFee;

        assertEq(usdc.balanceOf(trader1), trader1Before + payout);
    }

    function test_SettleBet_MaxMatchers() public {
        // Test with MAX_MATCHERS (100) fills
        uint256 creatorStake = 10000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Create 100 matchers, each filling 100e6
        for (uint256 i = 0; i < 100; i++) {
            address matcher = address(uint160(100 + i));
            usdc.mint(matcher, 100e6);
            vm.prank(matcher);
            usdc.approve(address(core), type(uint256).max);
            vm.prank(matcher);
            core.matchBet(betId, 100e6);
        }

        // Settlement should succeed
        vm.prank(resolver);
        core.settleBet(betId, false);

        // Verify bet is settled
        assertEq(uint256(core.getBetState(betId).status), uint256(AgiArenaCore.BetStatus.Settled));

        // Verify contract has no remaining balance
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_MatchBet_TooManyMatchers() public {
        uint256 creatorStake = 10100e6;

        // Mint extra USDC for trader1 to cover the full bet
        usdc.mint(trader1, 200e6);

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        // Create MAX_MATCHERS (100) fills
        for (uint256 i = 0; i < 100; i++) {
            address matcher = address(uint160(100 + i));
            usdc.mint(matcher, 100e6);
            vm.prank(matcher);
            usdc.approve(address(core), type(uint256).max);
            vm.prank(matcher);
            core.matchBet(betId, 100e6);
        }

        // 101st matcher should fail
        address extraMatcher = address(uint160(200));
        usdc.mint(extraMatcher, 100e6);
        vm.prank(extraMatcher);
        usdc.approve(address(core), type(uint256).max);

        vm.prank(extraMatcher);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.TooManyMatchers.selector, 101, 100));
        core.matchBet(betId, 100e6);
    }

    function test_SettleBet_ZeroFee_SmallPot() public {
        // Small pot where fee rounds to 0
        uint256 creatorStake = 1; // 0.000001 USDC

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, ODDS_EVEN, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, 1);

        vm.prank(resolver);
        core.settleBet(betId, true);

        // Total pot = 2, fee = 0 (truncated), payout = 2
        assertEq(usdc.balanceOf(trader1), INITIAL_BALANCE - 1 + 2);
    }

    function testFuzz_SettleBet_CreatorWins(uint256 creatorStake, uint32 oddsBps) public {
        creatorStake = bound(creatorStake, 1e6, INITIAL_BALANCE);
        oddsBps = uint32(bound(oddsBps, 100, 100_000));

        uint256 requiredMatch = (creatorStake * ODDS_EVEN) / oddsBps;
        if (requiredMatch == 0 || requiredMatch > INITIAL_BALANCE) return;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, oddsBps, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, requiredMatch);

        uint256 trader1Before = usdc.balanceOf(trader1);

        vm.prank(resolver);
        core.settleBet(betId, true);

        // Verify creator received payout
        uint256 totalPot = creatorStake + requiredMatch;
        uint256 platformFee = (totalPot * 10) / 10000;
        uint256 expectedPayout = totalPot - platformFee;

        assertEq(usdc.balanceOf(trader1), trader1Before + expectedPayout);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function testFuzz_SettleBet_MatcherWins(uint256 creatorStake, uint32 oddsBps) public {
        creatorStake = bound(creatorStake, 1e6, INITIAL_BALANCE);
        oddsBps = uint32(bound(oddsBps, 100, 100_000));

        uint256 requiredMatch = (creatorStake * ODDS_EVEN) / oddsBps;
        if (requiredMatch == 0 || requiredMatch > INITIAL_BALANCE) return;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_SNAPSHOT_ID, TEST_POSITION_BITMAP, TEST_JSON_REF, creatorStake, oddsBps, block.timestamp + DEFAULT_DEADLINE);

        vm.prank(trader2);
        core.matchBet(betId, requiredMatch);

        uint256 trader2Before = usdc.balanceOf(trader2);

        vm.prank(resolver);
        core.settleBet(betId, false);

        // Verify matcher received payout
        uint256 totalPot = creatorStake + requiredMatch;
        uint256 platformFee = (totalPot * 10) / 10000;
        uint256 expectedPayout = totalPot - platformFee;

        assertEq(usdc.balanceOf(trader2), trader2Before + expectedPayout);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    // ============ Helper Functions ============

    function _generateLargePortfolioRef(uint256 numMarkets) internal pure returns (string memory) {
        bytes memory ref = abi.encodePacked(
            "agent-1-portfolio-",
            _uint2str(numMarkets),
            "-markets-ipfs-QmSimulatedHashFor",
            _uint2str(numMarkets),
            "MarketsPortfolio"
        );
        return string(ref);
    }

    function _uint2str(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
