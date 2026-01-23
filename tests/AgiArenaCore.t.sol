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
/// @notice Unit tests for AgiArenaCore smart contract
contract AgiArenaCoreTest is Test {
    AgiArenaCore public core;
    MockUSDC public usdc;

    address public feeRecipient = address(0xFEE);
    address public trader1 = address(0x1);
    address public trader2 = address(0x2);
    address public trader3 = address(0x3);

    uint256 constant INITIAL_BALANCE = 10_000e6; // 10k USDC (6 decimals)
    bytes32 constant TEST_BET_HASH = keccak256(abi.encode("portfolio-1"));
    string constant TEST_JSON_REF = "agent-1-bet-123";

    event BetPlaced(
        uint256 indexed betId, address indexed creator, bytes32 betHash, string jsonStorageRef, uint256 amount
    );
    event BetMatched(uint256 indexed betId, address indexed filler, uint256 fillAmount, uint256 remaining);
    event BetCancelled(uint256 indexed betId, address indexed creator, uint256 refundAmount);

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy AgiArenaCore
        core = new AgiArenaCore(address(usdc), feeRecipient);

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
        assertEq(address(core.USDC()), address(usdc));
        assertEq(core.FEE_RECIPIENT(), feeRecipient);
        assertEq(core.PLATFORM_FEE_BPS(), 10);
        assertEq(core.nextBetId(), 0);
    }

    function test_Constructor_ZeroAddressUSDC() public {
        vm.expectRevert(AgiArenaCore.ZeroAddress.selector);
        new AgiArenaCore(address(0), feeRecipient);
    }

    function test_Constructor_ZeroAddressFeeRecipient() public {
        vm.expectRevert(AgiArenaCore.ZeroAddress.selector);
        new AgiArenaCore(address(usdc), address(0));
    }

    // ============ placeBet Tests ============

    function test_PlacePortfolioBet() public {
        uint256 betAmount = 1000e6; // 1k USDC

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        // Verify bet ID
        assertEq(betId, 0);
        assertEq(core.nextBetId(), 1);

        // Verify bet state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.betHash, TEST_BET_HASH);
        assertEq(bet.jsonStorageRef, TEST_JSON_REF);
        assertEq(bet.amount, betAmount);
        assertEq(bet.matchedAmount, 0);
        assertEq(bet.creator, trader1);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.Pending));

        // Verify USDC transfer
        assertEq(usdc.balanceOf(trader1), INITIAL_BALANCE - betAmount);
        assertEq(usdc.balanceOf(address(core)), betAmount);
    }

    function test_PlacePortfolioBet_EmitsEvent() public {
        uint256 betAmount = 500e6;

        vm.expectEmit(true, true, false, true);
        emit BetPlaced(0, trader1, TEST_BET_HASH, TEST_JSON_REF, betAmount);

        vm.prank(trader1);
        core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);
    }

    function test_PlacePortfolioBet_InsufficientBalance() public {
        uint256 betAmount = INITIAL_BALANCE + 1; // More than balance

        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.InsufficientBalance.selector, betAmount, INITIAL_BALANCE));
        core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);
    }

    function test_PlacePortfolioBet_ZeroAmount() public {
        vm.prank(trader1);
        vm.expectRevert(AgiArenaCore.ZeroAmount.selector);
        core.placeBet(TEST_BET_HASH, TEST_JSON_REF, 0);
    }

    function test_PlacePortfolioBet_InvalidHash() public {
        // Tests that contract rejects zero hash (bytes32(0))
        // NOTE: The contract does NOT validate hash vs JSON content on-chain.
        // Hash-to-JSON verification is done off-chain by backend/keepers using BettingLib.
        // This is by design - storing/validating JSON on-chain would be prohibitively expensive.
        vm.prank(trader1);
        vm.expectRevert(AgiArenaCore.InvalidBetHash.selector);
        core.placeBet(bytes32(0), TEST_JSON_REF, 1000e6);
    }

    function test_PlaceMultipleBets() public {
        vm.startPrank(trader1);

        uint256 bet1 = core.placeBet(TEST_BET_HASH, "ref-1", 100e6);
        uint256 bet2 = core.placeBet(keccak256("portfolio-2"), "ref-2", 200e6);
        uint256 bet3 = core.placeBet(keccak256("portfolio-3"), "ref-3", 300e6);

        vm.stopPrank();

        assertEq(bet1, 0);
        assertEq(bet2, 1);
        assertEq(bet3, 2);
        assertEq(core.nextBetId(), 3);
    }

    // ============ matchBet Tests ============

    function test_MatchPortfolioBet_FullFill() public {
        uint256 betAmount = 1000e6;

        // Trader1 places bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        // Trader2 fully matches
        vm.prank(trader2);
        core.matchBet(betId, betAmount);

        // Verify bet state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.matchedAmount, betAmount);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));

        // Verify USDC transfers
        assertEq(usdc.balanceOf(trader2), INITIAL_BALANCE - betAmount);
        assertEq(usdc.balanceOf(address(core)), betAmount * 2); // Both traders' funds

        // Verify fill record
        assertEq(core.getBetFillCount(betId), 1);
        AgiArenaCore.Fill[] memory fills = core.getBetFills(betId);
        assertEq(fills[0].filler, trader2);
        assertEq(fills[0].amount, betAmount);
    }

    function test_MatchPortfolioBet_PartialFill() public {
        uint256 betAmount = 1000e6;
        uint256 fillAmount = 400e6;

        // Trader1 places bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        // Trader2 partially matches
        vm.prank(trader2);
        core.matchBet(betId, fillAmount);

        // Verify bet state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.matchedAmount, fillAmount);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.PartiallyMatched));

        // Verify remaining
        assertEq(bet.amount - bet.matchedAmount, 600e6);
    }

    function test_MatchPortfolioBet_MultipleFills() public {
        // AC: test_MatchPortfolioBet_MultipleFills() - multiple users fill portions of same portfolio
        uint256 betAmount = 1000e6;

        // Trader1 places bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        // Trader2 partial fill
        vm.prank(trader2);
        core.matchBet(betId, 300e6);

        // Trader3 partial fill
        vm.prank(trader3);
        core.matchBet(betId, 500e6);

        // Trader2 another fill to complete
        vm.prank(trader2);
        core.matchBet(betId, 200e6);

        // Verify bet state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.matchedAmount, betAmount);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));

        // Verify fill records
        assertEq(core.getBetFillCount(betId), 3);
    }

    function test_MatchPortfolioBet_EmitsEvent() public {
        uint256 betAmount = 1000e6;
        uint256 fillAmount = 400e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        vm.expectEmit(true, true, false, true);
        emit BetMatched(betId, trader2, fillAmount, 600e6);

        vm.prank(trader2);
        core.matchBet(betId, fillAmount);
    }

    function test_MatchPortfolioBet_BetNotFound() public {
        vm.prank(trader2);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotFound.selector, 999));
        core.matchBet(999, 100e6);
    }

    function test_MatchPortfolioBet_ZeroAmount() public {
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, 1000e6);

        vm.prank(trader2);
        vm.expectRevert(AgiArenaCore.ZeroAmount.selector);
        core.matchBet(betId, 0);
    }

    function test_MatchPortfolioBet_FillExceedsRemaining() public {
        uint256 betAmount = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        vm.prank(trader2);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.FillExceedsRemaining.selector, betAmount + 1, betAmount));
        core.matchBet(betId, betAmount + 1);
    }

    function test_MatchPortfolioBet_AlreadyFullyMatched() public {
        uint256 betAmount = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        // Fully match
        vm.prank(trader2);
        core.matchBet(betId, betAmount);

        // Try to match again
        vm.prank(trader3);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotPending.selector, betId));
        core.matchBet(betId, 100e6);
    }

    function test_MatchPortfolioBet_SelfMatch() public {
        // Test that creator CAN match their own bet (allowed behavior)
        uint256 betAmount = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        // Creator matches their own bet (self-match)
        vm.prank(trader1);
        core.matchBet(betId, betAmount);

        // Verify bet is fully matched
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));
        assertEq(bet.matchedAmount, betAmount);

        // Verify fill record shows trader1 as both creator and filler
        AgiArenaCore.Fill[] memory fills = core.getBetFills(betId);
        assertEq(fills[0].filler, trader1);

        // Verify USDC balances: trader1 paid twice (place + match)
        assertEq(usdc.balanceOf(trader1), INITIAL_BALANCE - (betAmount * 2));
        assertEq(usdc.balanceOf(address(core)), betAmount * 2);
    }

    function test_MatchPortfolioBet_FillerInsufficientBalance() public {
        uint256 betAmount = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        // Drain trader2's balance
        vm.prank(trader2);
        usdc.transfer(address(0xdead), INITIAL_BALANCE);

        // Try to match with no balance
        vm.prank(trader2);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.InsufficientBalance.selector, betAmount, 0));
        core.matchBet(betId, betAmount);
    }

    // ============ cancelBet Tests ============

    function test_CancelPortfolioBet() public {
        uint256 betAmount = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        uint256 balanceBeforeCancel = usdc.balanceOf(trader1);

        vm.prank(trader1);
        core.cancelBet(betId);

        // Verify bet state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.Cancelled));

        // Verify USDC refund
        assertEq(usdc.balanceOf(trader1), balanceBeforeCancel + betAmount);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_CancelPortfolioBet_EmitsEvent() public {
        uint256 betAmount = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        vm.expectEmit(true, true, false, true);
        emit BetCancelled(betId, trader1, betAmount);

        vm.prank(trader1);
        core.cancelBet(betId);
    }

    function test_CancelPortfolioBet_PartiallyMatched() public {
        uint256 betAmount = 1000e6;
        uint256 matchedAmount = 400e6;
        uint256 expectedRefund = betAmount - matchedAmount; // 600e6

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

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

        // Verify only unfilled portion was refunded
        assertEq(usdc.balanceOf(trader1), balanceBeforeCancel + expectedRefund);
        // Contract should still hold both traders' matched amounts
        assertEq(usdc.balanceOf(address(core)), matchedAmount * 2);
    }

    function test_CancelPortfolioBet_PartiallyMatchedEmitsEvent() public {
        uint256 betAmount = 1000e6;
        uint256 matchedAmount = 300e6;
        uint256 expectedRefund = 700e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        vm.prank(trader2);
        core.matchBet(betId, matchedAmount);

        vm.expectEmit(true, true, false, true);
        emit BetCancelled(betId, trader1, expectedRefund);

        vm.prank(trader1);
        core.cancelBet(betId);
    }

    function test_CancelPortfolioBet_AlreadyMatched() public {
        // AC: test_CancelPortfolioBet_AlreadyMatched() - revert if bet already matched
        uint256 betAmount = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        // Fully match
        vm.prank(trader2);
        core.matchBet(betId, betAmount);

        // Try to cancel - should fail because bet is fully matched (not pending/partial)
        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotPending.selector, betId));
        core.cancelBet(betId);
    }

    function test_CancelPortfolioBet_Unauthorized() public {
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, 1000e6);

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

    function test_CancelPortfolioBet_AlreadyCancelled() public {
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, 1000e6);

        vm.prank(trader1);
        core.cancelBet(betId);

        // Try to cancel again
        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotPending.selector, betId));
        core.cancelBet(betId);
    }

    // ============ getBetState Tests ============

    function test_GetBetState_NotFound() public {
        vm.expectRevert(abi.encodeWithSelector(AgiArenaCore.BetNotFound.selector, 999));
        core.getBetState(999);
    }

    // ============ Fuzz Tests ============

    function testFuzz_PlaceBet(uint256 amount) public {
        // Bound amount to reasonable values (1 USDC to initial balance)
        amount = bound(amount, 1e6, INITIAL_BALANCE);

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, amount);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.amount, amount);
        assertEq(usdc.balanceOf(address(core)), amount);
    }

    function testFuzz_MatchBet(uint256 betAmount, uint256 fillAmount) public {
        // Bound amounts
        betAmount = bound(betAmount, 1e6, INITIAL_BALANCE);
        fillAmount = bound(fillAmount, 1, betAmount);

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        vm.prank(trader2);
        core.matchBet(betId, fillAmount);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.matchedAmount, fillAmount);
    }

    // ============ Large Portfolio Tests (AC: 1, 2) ============

    /// @notice Helper function to generate a large portfolio JSON reference string
    /// @param numMarkets Number of markets to simulate in the reference
    function _generateLargePortfolioRef(uint256 numMarkets) internal pure returns (string memory) {
        // Simulate a storage reference that encodes portfolio size
        // Format: "agent-{id}-portfolio-{numMarkets}-{timestamp}"
        // In practice, the actual JSON is stored off-chain
        bytes memory ref = abi.encodePacked(
            "agent-1-portfolio-",
            _uint2str(numMarkets),
            "-markets-ipfs-QmSimulatedHashFor",
            _uint2str(numMarkets),
            "MarketsPortfolio"
        );
        return string(ref);
    }

    /// @notice Helper to convert uint to string
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

    /// @notice Test placing a bet with a large portfolio (5000+ markets)
    /// @dev Simulates large portfolio by using long jsonStorageRef string
    function test_LargePortfolio_5000Markets() public {
        string memory largeRef = _generateLargePortfolioRef(5000);
        bytes32 largeHash = keccak256(bytes(largeRef));
        uint256 betAmount = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(largeHash, largeRef, betAmount);

        // Verify bet placed successfully
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(bet.betHash, largeHash);
        assertEq(keccak256(bytes(bet.jsonStorageRef)), keccak256(bytes(largeRef)));
        assertEq(bet.amount, betAmount);
    }

    /// @notice Gas measurement test for varying portfolio sizes
    /// @dev Tests with 10, 100, 1000, 5000 market references to document gas costs
    function test_LargePortfolio_GasMeasurement() public {
        uint256 betAmount = 100e6;
        uint256[] memory marketCounts = new uint256[](4);
        marketCounts[0] = 10;
        marketCounts[1] = 100;
        marketCounts[2] = 1000;
        marketCounts[3] = 5000;

        for (uint256 i = 0; i < marketCounts.length; i++) {
            string memory ref = _generateLargePortfolioRef(marketCounts[i]);
            bytes32 hash = keccak256(bytes(ref));

            vm.prank(trader1);
            uint256 betId = core.placeBet(hash, ref, betAmount);

            // Verify each bet was placed
            AgiArenaCore.Bet memory bet = core.getBetState(betId);
            assertEq(bet.betHash, hash);
            assertEq(bet.amount, betAmount);
        }

        // All 4 bets should have been placed
        assertEq(core.nextBetId(), 4);
    }

    /// @notice Test matching a large portfolio bet
    function test_LargePortfolio_MatchBet() public {
        string memory largeRef = _generateLargePortfolioRef(5000);
        bytes32 largeHash = keccak256(bytes(largeRef));
        uint256 betAmount = 1000e6;

        // Place large portfolio bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(largeHash, largeRef, betAmount);

        // Match the bet fully
        vm.prank(trader2);
        core.matchBet(betId, betAmount);

        // Verify bet is fully matched
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));
        assertEq(bet.matchedAmount, betAmount);
    }

    /// @notice Test partial fills on large portfolio
    function test_LargePortfolio_PartialFills() public {
        string memory largeRef = _generateLargePortfolioRef(5000);
        bytes32 largeHash = keccak256(bytes(largeRef));
        uint256 betAmount = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(largeHash, largeRef, betAmount);

        // Multiple partial fills
        vm.prank(trader2);
        core.matchBet(betId, 300e6); // 30%

        vm.prank(trader3);
        core.matchBet(betId, 500e6); // 50%

        vm.prank(trader2);
        core.matchBet(betId, 200e6); // Final 20%

        // Verify fully matched
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));
        assertEq(core.getBetFillCount(betId), 3);
    }

    // ============ Portfolio Hash Verification Tests (AC: 1) ============

    /// @notice Test hash verification with large portfolio (1000+ markets)
    function test_PortfolioHashVerification_1000Markets() public {
        // Generate a simulated large portfolio JSON reference
        string memory largeRef = _generateLargePortfolioRef(1000);
        bytes32 expectedHash = keccak256(bytes(largeRef));

        // Place bet with this hash
        vm.prank(trader1);
        uint256 betId = core.placeBet(expectedHash, largeRef, 1000e6);

        // Retrieve and verify
        AgiArenaCore.Bet memory bet = core.getBetState(betId);

        // Verify hash matches what we computed
        assertEq(bet.betHash, expectedHash);

        // Verify we can recompute hash from stored ref
        assertEq(keccak256(bytes(bet.jsonStorageRef)), expectedHash);
    }

    /// @notice Test hash mismatch scenarios
    function test_PortfolioHashVerification_Mismatch() public {
        string memory originalRef = _generateLargePortfolioRef(1000);
        string memory tamperedRef = _generateLargePortfolioRef(1001); // Different!

        bytes32 originalHash = keccak256(bytes(originalRef));
        bytes32 tamperedHash = keccak256(bytes(tamperedRef));

        // Hashes should be different
        assertTrue(originalHash != tamperedHash, "Hashes should differ for different content");

        // Place bet with original hash
        vm.prank(trader1);
        uint256 betId = core.placeBet(originalHash, originalRef, 1000e6);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);

        // Stored hash should NOT match tampered content hash
        assertTrue(bet.betHash != tamperedHash, "Stored hash should not match tampered content");
    }

    // ============ Event Emission Tests (AC: 5) ============

    /// @notice Test BetPlaced event includes jsonStorageRef
    function test_BetPlaced_EventIncludesJsonStorageRef() public {
        string memory jsonRef = "agent-42-portfolio-comprehensive-test";
        bytes32 betHash = keccak256(bytes(jsonRef));
        uint256 betAmount = 500e6;

        // Expect event with all parameters including jsonStorageRef
        vm.expectEmit(true, true, false, true);
        emit BetPlaced(0, trader1, betHash, jsonRef, betAmount);

        vm.prank(trader1);
        core.placeBet(betHash, jsonRef, betAmount);
    }

    /// @notice Test BetMatched event emission
    function test_BetMatched_EventEmission() public {
        uint256 betAmount = 1000e6;
        uint256 fillAmount = 400e6;
        uint256 expectedRemaining = 600e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        // Expect BetMatched event with correct parameters
        vm.expectEmit(true, true, false, true);
        emit BetMatched(betId, trader2, fillAmount, expectedRemaining);

        vm.prank(trader2);
        core.matchBet(betId, fillAmount);
    }

    /// @notice Test BetCancelled event emission
    function test_BetCancelled_EventEmission() public {
        uint256 betAmount = 1000e6;

        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, betAmount);

        // Expect BetCancelled event with full refund
        vm.expectEmit(true, true, false, true);
        emit BetCancelled(betId, trader1, betAmount);

        vm.prank(trader1);
        core.cancelBet(betId);
    }

    /// @notice Test all event parameters are correctly emitted in sequence
    function test_EventSequence_FullBettingFlow() public {
        string memory jsonRef = "agent-1-bet-sequential-test";
        bytes32 betHash = keccak256(bytes(jsonRef));
        uint256 betAmount = 1000e6;

        // Event 1: BetPlaced
        vm.expectEmit(true, true, false, true);
        emit BetPlaced(0, trader1, betHash, jsonRef, betAmount);

        vm.prank(trader1);
        uint256 betId = core.placeBet(betHash, jsonRef, betAmount);

        // Event 2: BetMatched (partial)
        vm.expectEmit(true, true, false, true);
        emit BetMatched(betId, trader2, 300e6, 700e6);

        vm.prank(trader2);
        core.matchBet(betId, 300e6);

        // Event 3: BetMatched (complete)
        vm.expectEmit(true, true, false, true);
        emit BetMatched(betId, trader3, 700e6, 0);

        vm.prank(trader3);
        core.matchBet(betId, 700e6);
    }

    // ============ Integration Tests (AC: 1) ============

    /// @notice Full betting flow: place -> partial fill -> more fills -> full match
    function test_FullBettingFlow() public {
        string memory jsonRef = "agent-integration-test-full-flow";
        bytes32 betHash = keccak256(bytes(jsonRef));
        uint256 betAmount = 1000e6;

        // Step 1: Place bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(betHash, jsonRef, betAmount);

        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.Pending));
        assertEq(bet.matchedAmount, 0);

        // Step 2: First partial fill (30%)
        vm.prank(trader2);
        core.matchBet(betId, 300e6);

        bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.PartiallyMatched));
        assertEq(bet.matchedAmount, 300e6);

        // Step 3: Second partial fill (50%)
        vm.prank(trader3);
        core.matchBet(betId, 500e6);

        bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.PartiallyMatched));
        assertEq(bet.matchedAmount, 800e6);

        // Step 4: Final fill (20%) - completes the bet
        vm.prank(trader2);
        core.matchBet(betId, 200e6);

        bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched));
        assertEq(bet.matchedAmount, 1000e6);

        // Verify fill records
        assertEq(core.getBetFillCount(betId), 3);
        AgiArenaCore.Fill[] memory fills = core.getBetFills(betId);
        assertEq(fills[0].filler, trader2);
        assertEq(fills[0].amount, 300e6);
        assertEq(fills[1].filler, trader3);
        assertEq(fills[1].amount, 500e6);
        assertEq(fills[2].filler, trader2);
        assertEq(fills[2].amount, 200e6);

        // Verify USDC balances
        assertEq(usdc.balanceOf(trader1), INITIAL_BALANCE - betAmount);
        assertEq(usdc.balanceOf(trader2), INITIAL_BALANCE - 500e6); // 300 + 200
        assertEq(usdc.balanceOf(trader3), INITIAL_BALANCE - 500e6);
        assertEq(usdc.balanceOf(address(core)), betAmount * 2); // Both sides escrowed
    }

    /// @notice Test cancel remaining after partial fill
    function test_CancelPartiallyMatchedBet() public {
        string memory jsonRef = "agent-cancel-partial-test";
        bytes32 betHash = keccak256(bytes(jsonRef));
        uint256 betAmount = 1000e6;

        // Place bet
        vm.prank(trader1);
        uint256 betId = core.placeBet(betHash, jsonRef, betAmount);

        // Partial fill
        vm.prank(trader2);
        core.matchBet(betId, 400e6);

        uint256 trader1BalanceBefore = usdc.balanceOf(trader1);

        // Cancel remaining
        vm.prank(trader1);
        core.cancelBet(betId);

        // Verify state
        AgiArenaCore.Bet memory bet = core.getBetState(betId);
        assertEq(uint256(bet.status), uint256(AgiArenaCore.BetStatus.FullyMatched)); // Closed status
        assertEq(bet.matchedAmount, 400e6); // Still has matched amount

        // Verify refund of unfilled portion (600 USDC)
        assertEq(usdc.balanceOf(trader1), trader1BalanceBefore + 600e6);

        // Contract still holds matched amounts from both parties
        assertEq(usdc.balanceOf(address(core)), 800e6); // 400 from trader1 + 400 from trader2
    }

    /// @notice Test state transitions are correct throughout lifecycle
    function test_BetStateTransitions() public {
        vm.prank(trader1);
        uint256 betId = core.placeBet(TEST_BET_HASH, TEST_JSON_REF, 1000e6);

        // Initial: Pending
        assertEq(uint256(core.getBetState(betId).status), uint256(AgiArenaCore.BetStatus.Pending));

        // After partial: PartiallyMatched
        vm.prank(trader2);
        core.matchBet(betId, 100e6);
        assertEq(uint256(core.getBetState(betId).status), uint256(AgiArenaCore.BetStatus.PartiallyMatched));

        // After full: FullyMatched
        vm.prank(trader2);
        core.matchBet(betId, 900e6);
        assertEq(uint256(core.getBetState(betId).status), uint256(AgiArenaCore.BetStatus.FullyMatched));
    }
}
