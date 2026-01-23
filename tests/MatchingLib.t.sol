// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/src/Test.sol";
import {MatchingLib} from "../src/libraries/MatchingLib.sol";

/// @title MatchingLibWrapper
/// @notice Wrapper contract to expose library functions for testing reverts
contract MatchingLibWrapper {
    function validateFill(
        uint256 fillAmount,
        uint256 remaining,
        uint8 status
    ) external pure returns (bool) {
        return MatchingLib.validateFill(fillAmount, remaining, status);
    }

    function getRemainingAmount(
        uint256 amount,
        uint256 matchedAmount
    ) external pure returns (uint256) {
        return MatchingLib.getRemainingAmount(amount, matchedAmount);
    }

    function calculateFillResult(
        uint256 currentMatchedAmount,
        uint256 totalAmount,
        uint256 fillAmount
    ) external pure returns (uint256, uint256, uint8) {
        return MatchingLib.calculateFillResult(currentMatchedAmount, totalAmount, fillAmount);
    }

    function getMatchPercentage(
        uint256 amount,
        uint256 matchedAmount
    ) external pure returns (uint256) {
        return MatchingLib.getMatchPercentage(amount, matchedAmount);
    }
}

/// @title MatchingLibTest
/// @notice Test suite for MatchingLib library functions
contract MatchingLibTest is Test {
    MatchingLibWrapper public wrapper;

    function setUp() public {
        wrapper = new MatchingLibWrapper();
    }
    // ============ Test Constants ============
    uint256 constant BET_AMOUNT = 1000e6; // 1000 USDC
    uint256 constant PARTIAL_FILL = 300e6; // 300 USDC

    // ============ calculateFillAmount Tests ============

    function test_calculateFillAmount_ValidPartialFill() public pure {
        // Available: 1000, Requested: 300 -> Should return 300
        uint256 result = MatchingLib.calculateFillAmount(BET_AMOUNT, PARTIAL_FILL);
        assertEq(result, PARTIAL_FILL, "Should return requested amount when less than available");
    }

    function test_calculateFillAmount_FullFill() public pure {
        // Available: 1000, Requested: 1500 -> Should return 1000 (available)
        uint256 result = MatchingLib.calculateFillAmount(BET_AMOUNT, 1500e6);
        assertEq(result, BET_AMOUNT, "Should return available amount when requested exceeds");
    }

    function test_calculateFillAmount_ExactMatch() public pure {
        // Available: 1000, Requested: 1000 -> Should return 1000
        uint256 result = MatchingLib.calculateFillAmount(BET_AMOUNT, BET_AMOUNT);
        assertEq(result, BET_AMOUNT, "Should return exact amount when equal");
    }

    function test_calculateFillAmount_ZeroAvailable() public pure {
        // Available: 0, Requested: 300 -> Should return 0 (bet fully matched)
        uint256 result = MatchingLib.calculateFillAmount(0, PARTIAL_FILL);
        assertEq(result, 0, "Should return 0 when bet is fully matched");
    }

    function test_calculateFillAmount_ZeroRequested() public pure {
        // Available: 1000, Requested: 0 -> Should return 0
        uint256 result = MatchingLib.calculateFillAmount(BET_AMOUNT, 0);
        assertEq(result, 0, "Should return 0 when nothing requested");
    }

    function testFuzz_calculateFillAmount(uint256 available, uint256 requested) public pure {
        uint256 result = MatchingLib.calculateFillAmount(available, requested);

        if (available == 0) {
            assertEq(result, 0, "Zero available should return 0");
        } else {
            assertLe(result, available, "Result should never exceed available");
            assertLe(result, requested, "Result should never exceed requested");

            if (requested <= available) {
                assertEq(result, requested, "Should return requested when within available");
            } else {
                assertEq(result, available, "Should return available when requested exceeds");
            }
        }
    }

    // ============ getRemainingAmount Tests ============

    function test_getRemainingAmount_NoMatch() public pure {
        uint256 remaining = MatchingLib.getRemainingAmount(BET_AMOUNT, 0);
        assertEq(remaining, BET_AMOUNT, "Should return full amount when no matches");
    }

    function test_getRemainingAmount_PartialMatch() public pure {
        uint256 remaining = MatchingLib.getRemainingAmount(BET_AMOUNT, PARTIAL_FILL);
        assertEq(remaining, BET_AMOUNT - PARTIAL_FILL, "Should return remaining after partial");
    }

    function test_getRemainingAmount_FullyMatched() public pure {
        uint256 remaining = MatchingLib.getRemainingAmount(BET_AMOUNT, BET_AMOUNT);
        assertEq(remaining, 0, "Should return 0 when fully matched");
    }

    // ============ isFullyMatched Tests ============

    function test_isFullyMatched_True() public pure {
        bool result = MatchingLib.isFullyMatched(BET_AMOUNT, BET_AMOUNT);
        assertTrue(result, "Should return true when fully matched");
    }

    function test_isFullyMatched_False_NoMatch() public pure {
        bool result = MatchingLib.isFullyMatched(BET_AMOUNT, 0);
        assertFalse(result, "Should return false when no matches");
    }

    function test_isFullyMatched_False_PartialMatch() public pure {
        bool result = MatchingLib.isFullyMatched(BET_AMOUNT, PARTIAL_FILL);
        assertFalse(result, "Should return false when partially matched");
    }

    // ============ getMatchPercentage Tests ============

    function test_getMatchPercentage_Zero() public pure {
        uint256 percentage = MatchingLib.getMatchPercentage(BET_AMOUNT, 0);
        assertEq(percentage, 0, "Should return 0% when no matches");
    }

    function test_getMatchPercentage_Fifty() public pure {
        uint256 percentage = MatchingLib.getMatchPercentage(BET_AMOUNT, BET_AMOUNT / 2);
        assertEq(percentage, 5000, "Should return 50% (5000 bps) when half matched");
    }

    function test_getMatchPercentage_Full() public pure {
        uint256 percentage = MatchingLib.getMatchPercentage(BET_AMOUNT, BET_AMOUNT);
        assertEq(percentage, 10000, "Should return 100% (10000 bps) when fully matched");
    }

    function test_getMatchPercentage_Thirty() public pure {
        // 300 / 1000 = 30% = 3000 bps
        uint256 percentage = MatchingLib.getMatchPercentage(BET_AMOUNT, PARTIAL_FILL);
        assertEq(percentage, 3000, "Should return 30% (3000 bps)");
    }

    function test_getMatchPercentage_ZeroAmount() public pure {
        uint256 percentage = MatchingLib.getMatchPercentage(0, 0);
        assertEq(percentage, 0, "Should return 0 when amount is 0 (avoid div by zero)");
    }

    // ============ determinePostFillStatus Tests ============

    function test_determinePostFillStatus_FullyMatched() public pure {
        MatchingLib.BetStatus status = MatchingLib.determinePostFillStatus(0);
        assertEq(uint8(status), uint8(MatchingLib.BetStatus.FullyMatched), "Should return FullyMatched when 0 remaining");
    }

    function test_determinePostFillStatus_PartiallyMatched() public pure {
        MatchingLib.BetStatus status = MatchingLib.determinePostFillStatus(100);
        assertEq(uint8(status), uint8(MatchingLib.BetStatus.PartiallyMatched), "Should return PartiallyMatched when remaining > 0");
    }

    // ============ validateFill Tests ============

    function test_validateFill_Success() public pure {
        // Status 0 = Pending, fillAmount = 300, remaining = 1000
        bool result = MatchingLib.validateFill(PARTIAL_FILL, BET_AMOUNT, 0);
        assertTrue(result, "Valid fill should return true");
    }

    function test_validateFill_Success_PartiallyMatched() public pure {
        // Status 1 = PartiallyMatched
        bool result = MatchingLib.validateFill(PARTIAL_FILL, 700e6, 1);
        assertTrue(result, "Valid fill on PartiallyMatched bet should succeed");
    }

    function test_validateFill_ExactRemaining() public pure {
        // Fill exactly the remaining amount
        bool result = MatchingLib.validateFill(BET_AMOUNT, BET_AMOUNT, 0);
        assertTrue(result, "Fill equal to remaining should succeed");
    }

    function test_validateFill_ZeroAmount() public {
        vm.expectRevert(MatchingLib.ZeroFillAmount.selector);
        wrapper.validateFill(0, BET_AMOUNT, 0);
    }

    function test_validateFill_ExceedsRemaining() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MatchingLib.FillExceedsRemaining.selector,
                1500e6,
                BET_AMOUNT
            )
        );
        wrapper.validateFill(1500e6, BET_AMOUNT, 0);
    }

    function test_validateFill_BetNotMatchable_FullyMatched() public {
        // Status 2 = FullyMatched, should not be matchable
        vm.expectRevert(
            abi.encodeWithSelector(MatchingLib.BetNotMatchable.selector, 2)
        );
        wrapper.validateFill(PARTIAL_FILL, BET_AMOUNT, 2);
    }

    function test_validateFill_BetNotMatchable_Cancelled() public {
        // Status 3 = Cancelled, should not be matchable
        vm.expectRevert(
            abi.encodeWithSelector(MatchingLib.BetNotMatchable.selector, 3)
        );
        wrapper.validateFill(PARTIAL_FILL, BET_AMOUNT, 3);
    }

    function test_validateFill_BetNotMatchable_Settling() public {
        // Status 4 = Settling, should not be matchable
        vm.expectRevert(
            abi.encodeWithSelector(MatchingLib.BetNotMatchable.selector, 4)
        );
        wrapper.validateFill(PARTIAL_FILL, BET_AMOUNT, 4);
    }

    function test_validateFill_BetNotMatchable_Settled() public {
        // Status 5 = Settled, should not be matchable
        vm.expectRevert(
            abi.encodeWithSelector(MatchingLib.BetNotMatchable.selector, 5)
        );
        wrapper.validateFill(PARTIAL_FILL, BET_AMOUNT, 5);
    }

    // ============ willCompleteMatch Tests ============

    function test_willCompleteMatch_True_ExactAmount() public pure {
        bool result = MatchingLib.willCompleteMatch(BET_AMOUNT, BET_AMOUNT);
        assertTrue(result, "Should return true when fill equals remaining");
    }

    function test_willCompleteMatch_True_ExceedsRemaining() public pure {
        bool result = MatchingLib.willCompleteMatch(1500e6, BET_AMOUNT);
        assertTrue(result, "Should return true when fill exceeds remaining");
    }

    function test_willCompleteMatch_False_PartialFill() public pure {
        bool result = MatchingLib.willCompleteMatch(PARTIAL_FILL, BET_AMOUNT);
        assertFalse(result, "Should return false for partial fill");
    }

    // ============ calculateFillResult Tests ============

    function test_calculateFillResult_PartialFill() public pure {
        (uint256 newMatched, uint256 newRemaining, uint8 newStatus) =
            MatchingLib.calculateFillResult(0, BET_AMOUNT, PARTIAL_FILL);

        assertEq(newMatched, PARTIAL_FILL, "Matched amount should equal fill");
        assertEq(newRemaining, BET_AMOUNT - PARTIAL_FILL, "Remaining should be correct");
        assertEq(newStatus, uint8(MatchingLib.BetStatus.PartiallyMatched), "Status should be PartiallyMatched");
    }

    function test_calculateFillResult_FullFill() public pure {
        (uint256 newMatched, uint256 newRemaining, uint8 newStatus) =
            MatchingLib.calculateFillResult(0, BET_AMOUNT, BET_AMOUNT);

        assertEq(newMatched, BET_AMOUNT, "Matched amount should equal total");
        assertEq(newRemaining, 0, "Remaining should be 0");
        assertEq(newStatus, uint8(MatchingLib.BetStatus.FullyMatched), "Status should be FullyMatched");
    }

    function test_calculateFillResult_SecondPartialFill() public pure {
        // First fill: 300, Second fill: 400 -> Total matched: 700
        (uint256 newMatched, uint256 newRemaining, uint8 newStatus) =
            MatchingLib.calculateFillResult(PARTIAL_FILL, BET_AMOUNT, 400e6);

        assertEq(newMatched, 700e6, "Matched amount should be 700");
        assertEq(newRemaining, 300e6, "Remaining should be 300");
        assertEq(newStatus, uint8(MatchingLib.BetStatus.PartiallyMatched), "Status should be PartiallyMatched");
    }

    function test_calculateFillResult_FinalFillCompletes() public pure {
        // Already matched: 700, Final fill: 300 -> Fully matched
        (uint256 newMatched, uint256 newRemaining, uint8 newStatus) =
            MatchingLib.calculateFillResult(700e6, BET_AMOUNT, 300e6);

        assertEq(newMatched, BET_AMOUNT, "Matched amount should equal total");
        assertEq(newRemaining, 0, "Remaining should be 0");
        assertEq(newStatus, uint8(MatchingLib.BetStatus.FullyMatched), "Status should be FullyMatched");
    }

    // ============ Fuzz Tests ============

    function testFuzz_getRemainingAmount(uint256 amount, uint256 matched) public pure {
        vm.assume(matched <= amount);

        uint256 remaining = MatchingLib.getRemainingAmount(amount, matched);
        assertEq(remaining, amount - matched, "Remaining should equal amount minus matched");
    }

    function testFuzz_getMatchPercentage(uint256 amount, uint256 matched) public pure {
        // Bound to realistic USDC amounts (up to 1 trillion USDC in 6 decimals)
        amount = bound(amount, 1, 1e18);
        matched = bound(matched, 0, amount);

        uint256 percentage = MatchingLib.getMatchPercentage(amount, matched);
        assertLe(percentage, 10000, "Percentage should not exceed 10000 bps");

        if (matched == 0) {
            assertEq(percentage, 0, "0 matched should be 0%");
        } else if (matched == amount) {
            assertEq(percentage, 10000, "Full match should be 100%");
        }
    }

    function testFuzz_calculateFillResult(
        uint256 currentMatched,
        uint256 totalAmount,
        uint256 fillAmount
    ) public pure {
        vm.assume(totalAmount > 0);
        vm.assume(currentMatched <= totalAmount);
        vm.assume(fillAmount <= totalAmount - currentMatched);

        (uint256 newMatched, uint256 newRemaining, uint8 newStatus) =
            MatchingLib.calculateFillResult(currentMatched, totalAmount, fillAmount);

        assertEq(newMatched, currentMatched + fillAmount, "New matched should be sum");
        assertEq(newRemaining, totalAmount - newMatched, "New remaining should be correct");

        if (newRemaining == 0) {
            assertEq(newStatus, uint8(MatchingLib.BetStatus.FullyMatched), "Should be FullyMatched");
        } else {
            assertEq(newStatus, uint8(MatchingLib.BetStatus.PartiallyMatched), "Should be PartiallyMatched");
        }
    }

    // ============ Edge Case / Boundary Tests ============

    function test_getRemainingAmount_Underflow() public {
        // When matchedAmount > amount, should revert with arithmetic underflow
        vm.expectRevert();
        wrapper.getRemainingAmount(100, 200);
    }

    function test_calculateFillResult_Overflow() public {
        // When fillAmount would cause newMatchedAmount to exceed totalAmount
        // This should revert with arithmetic underflow when calculating newRemaining
        vm.expectRevert();
        wrapper.calculateFillResult(900e6, 1000e6, 200e6); // 900 + 200 = 1100 > 1000
    }

    function test_calculateFillAmount_MinimumValues() public pure {
        // Test with 1 wei amounts
        uint256 result = MatchingLib.calculateFillAmount(1, 1);
        assertEq(result, 1, "Should handle 1 wei amounts");

        result = MatchingLib.calculateFillAmount(1, 100);
        assertEq(result, 1, "Should cap at available even for tiny amounts");
    }

    function test_calculateFillAmount_LargeValues() public pure {
        // Test near max uint256 (but avoid overflow in test setup)
        uint256 largeAmount = type(uint256).max / 2;
        uint256 result = MatchingLib.calculateFillAmount(largeAmount, largeAmount);
        assertEq(result, largeAmount, "Should handle large amounts");

        result = MatchingLib.calculateFillAmount(largeAmount, largeAmount + 1);
        assertEq(result, largeAmount, "Should cap at available for large amounts");
    }

    function test_validateFill_MinimumValidFill() public pure {
        // 1 wei fill should be valid
        bool result = MatchingLib.validateFill(1, 1000e6, 0);
        assertTrue(result, "1 wei fill should be valid");
    }

    function test_getMatchPercentage_PrecisionLoss() public pure {
        // Document the precision loss behavior for edge cases
        // 1/3 should be 3333 bps (33.33%), loses the .33 repeating
        uint256 percentage = MatchingLib.getMatchPercentage(3, 1);
        assertEq(percentage, 3333, "1/3 should round down to 3333 bps");

        // 2/3 should be 6666 bps (66.66%)
        percentage = MatchingLib.getMatchPercentage(3, 2);
        assertEq(percentage, 6666, "2/3 should round down to 6666 bps");
    }

    function test_getMatchPercentage_VeryLargeNumbers() public pure {
        // Test the overflow protection path
        uint256 largeMatched = type(uint256).max / 5000; // Large enough to trigger overflow check
        uint256 largeAmount = largeMatched * 2;

        uint256 percentage = MatchingLib.getMatchPercentage(largeAmount, largeMatched);
        // Should be approximately 50% (5000 bps) with some precision loss
        assertGe(percentage, 4900, "Should be approximately 50%");
        assertLe(percentage, 5100, "Should be approximately 50%");
    }

    function test_getMatchPercentage_ScaleZeroEdgeCase() public {
        // Test the edge case where scale would be 0 (amount < 10000)
        // This hits the `if (scale == 0) scale = 1` branch in getMatchPercentage
        //
        // IMPORTANT DOCUMENTATION:
        // This branch is technically UNREACHABLE with valid bet data because:
        // - To enter overflow path: matchedAmount > type(uint256).max / 10000 (≈1.16e73)
        // - For scale = 0: amount < 10000
        // - But valid bets require: matchedAmount <= amount
        // - Therefore: matchedAmount > 1.16e73 AND amount < 10000 is impossible for valid bets
        //
        // The scale = 1 fallback exists as defensive coding but will overflow
        // when reached with these extreme values. We document this behavior here.
        uint256 hugeMatched = type(uint256).max / 9999; // Triggers overflow check
        uint256 tinyAmount = 9999; // Results in scale = amount / 10000 = 0

        // Expect arithmetic overflow when scale = 1 is used with huge matchedAmount
        vm.expectRevert();
        wrapper.getMatchPercentage(tinyAmount, hugeMatched);
    }

    function test_getMatchPercentage_ValidLargeMatchPreservesRatio() public pure {
        // Test that overflow protection path works correctly for VALID large values
        // where matchedAmount <= amount (the real-world invariant)
        uint256 largeAmount = type(uint256).max / 10000 + 1000; // Just over overflow threshold
        uint256 largeMatched = largeAmount / 2; // 50% match - valid bet state

        // This should NOT trigger overflow path since matchedAmount < threshold
        uint256 percentage = MatchingLib.getMatchPercentage(largeAmount, largeMatched);
        // Allow for 1 bps precision loss due to integer division
        assertGe(percentage, 4999, "Should be approximately 50%");
        assertLe(percentage, 5000, "Should be approximately 50%");
    }

    function test_isFullyMatched_BoundaryValues() public pure {
        // Test with 1 wei
        assertTrue(MatchingLib.isFullyMatched(1, 1), "1 wei fully matched");
        assertFalse(MatchingLib.isFullyMatched(2, 1), "2 wei with 1 matched not fully matched");

        // Test with large values
        uint256 large = type(uint128).max;
        assertTrue(MatchingLib.isFullyMatched(large, large), "Large values fully matched");
    }

    function test_willCompleteMatch_BoundaryOneWei() public pure {
        // Filling exactly 1 wei remaining
        assertTrue(MatchingLib.willCompleteMatch(1, 1), "1 wei fill of 1 wei remaining completes");
        assertFalse(MatchingLib.willCompleteMatch(1, 2), "1 wei fill of 2 wei remaining does not complete");
    }
}
