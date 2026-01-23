// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MatchingLib
/// @author AgiArena Team
/// @notice Library for partial fill matching logic in portfolio betting
/// @dev Provides utility functions for calculating fills, validating matching operations,
///      and tracking match state. Uses internal functions for gas efficiency (inlined at compile time).
///      This library accepts primitive types (uint256, uint8) rather than storage pointers,
///      enabling reuse across contracts with different struct layouts (e.g., ResolutionManager.sol).
library MatchingLib {
    // ============ Custom Errors ============

    /// @notice Thrown when fill amount is zero
    error ZeroFillAmount();

    /// @notice Thrown when fill amount exceeds remaining
    /// @param requested The requested fill amount
    /// @param remaining The remaining amount available
    error FillExceedsRemaining(uint256 requested, uint256 remaining);

    /// @notice Thrown when bet status does not allow matching
    /// @param currentStatus The current bet status code
    error BetNotMatchable(uint8 currentStatus);

    // ============ Enums ============

    /// @notice Status of a bet through its lifecycle
    /// @dev CRITICAL: Must stay in sync with BetStatus enum in AgiArenaCore.sol
    ///      If either enum is modified, both must be updated together.
    ///      Values are used as uint8 for cross-contract compatibility.
    enum BetStatus {
        Pending,           // 0 - Bet placed, waiting for matches
        PartiallyMatched,  // 1 - Some amount filled
        FullyMatched,      // 2 - All amount filled or remaining cancelled
        Cancelled,         // 3 - Fully cancelled by creator (no fills existed)
        Settling,          // 4 - Resolution in progress
        Settled            // 5 - Final outcome determined
    }

    // ============ Events ============

    /// @notice Event signature for partial fill completion
    /// @dev NOTE: This event is defined here for API consistency but CANNOT be emitted
    ///      by library functions (they are pure/view). Consuming contracts should either:
    ///      1. Import and emit this event directly, OR
    ///      2. Use their own event (e.g., AgiArenaCore uses BetMatched)
    ///      This event is provided as a reference implementation for future contracts.
    /// @param betId Unique identifier for the bet
    /// @param filler Address that filled the bet
    /// @param fillAmount Amount filled in this transaction
    /// @param jsonStorageRef Off-chain storage reference for portfolio
    /// @param remaining Amount still available for matching
    event PartialFillCompleted(
        uint256 indexed betId,
        address indexed filler,
        uint256 fillAmount,
        string jsonStorageRef,
        uint256 remaining
    );

    // ============ Pure Calculation Functions ============

    /// @notice Calculate the actual fill amount for a matching operation
    /// @dev Returns the minimum of available and requested, or 0 if fully matched
    /// @param availableAmount The remaining unfilled amount on the bet
    /// @param requestedFill The amount the filler wants to match
    /// @return The actual fill amount (min of available and requested)
    function calculateFillAmount(
        uint256 availableAmount,
        uint256 requestedFill
    ) internal pure returns (uint256) {
        if (availableAmount == 0) return 0;
        return requestedFill > availableAmount ? availableAmount : requestedFill;
    }

    /// @notice Get the remaining unfilled amount for a bet
    /// @dev Calculates remaining from amount and matchedAmount.
    ///      IMPORTANT: Caller must ensure matchedAmount <= amount.
    ///      Will revert with arithmetic underflow if matchedAmount > amount.
    /// @param amount The total bet amount
    /// @param matchedAmount The amount already filled (must be <= amount)
    /// @return The remaining unfilled amount
    function getRemainingAmount(
        uint256 amount,
        uint256 matchedAmount
    ) internal pure returns (uint256) {
        return amount - matchedAmount;
    }

    /// @notice Check if a bet is fully matched
    /// @dev Returns true when matchedAmount equals total amount
    /// @param amount The total bet amount
    /// @param matchedAmount The amount already filled
    /// @return True if fully matched, false otherwise
    function isFullyMatched(
        uint256 amount,
        uint256 matchedAmount
    ) internal pure returns (bool) {
        return matchedAmount == amount;
    }

    /// @notice Get the match percentage in basis points
    /// @dev Returns fill percentage * 10000 (e.g., 50% = 5000 bps)
    ///      Uses multiplication order that avoids overflow for reasonable amounts.
    ///      For very large numbers, uses a different calculation path with some precision loss.
    /// @param amount The total bet amount
    /// @param matchedAmount The amount already filled
    /// @return Match percentage in basis points (0-10000). Note: Integer division causes
    ///         precision loss (e.g., 1/3 returns 3333 not 3333.33). Callers requiring
    ///         exact percentages should use higher precision or handle rounding separately.
    function getMatchPercentage(
        uint256 amount,
        uint256 matchedAmount
    ) internal pure returns (uint256) {
        if (amount == 0) return 0;
        // For typical USDC amounts (up to 2^64), the standard formula works fine
        // Check if multiplication would overflow
        if (matchedAmount > type(uint256).max / 10000) {
            // For very large numbers, scale down both values to avoid overflow
            // Divide both by a common factor to maintain ratio while avoiding overflow
            uint256 scale = amount / 10000;
            if (scale == 0) scale = 1;
            return (matchedAmount / scale) * 10000 / (amount / scale);
        }
        return (matchedAmount * 10000) / amount;
    }

    /// @notice Determine the new status after a fill
    /// @dev Returns FullyMatched if no remaining, else PartiallyMatched
    /// @param remaining The remaining amount after the fill
    /// @return The new BetStatus
    function determinePostFillStatus(
        uint256 remaining
    ) internal pure returns (BetStatus) {
        return remaining == 0 ? BetStatus.FullyMatched : BetStatus.PartiallyMatched;
    }

    // ============ Validation Functions ============

    /// @notice Validate a fill operation
    /// @dev Checks that fill amount is valid and bet status allows matching
    /// @param fillAmount The requested fill amount
    /// @param remaining The remaining unfilled amount
    /// @param status The current bet status (as uint8 to avoid import issues)
    /// @return True if fill is valid
    function validateFill(
        uint256 fillAmount,
        uint256 remaining,
        uint8 status
    ) internal pure returns (bool) {
        // Check fill amount is not zero
        if (fillAmount == 0) revert ZeroFillAmount();

        // Check fill does not exceed remaining
        if (fillAmount > remaining) revert FillExceedsRemaining(fillAmount, remaining);

        // Check bet status allows matching (Pending = 0 or PartiallyMatched = 1)
        if (status > 1) revert BetNotMatchable(status);

        return true;
    }

    /// @notice Check if fill would complete the bet
    /// @dev Used to determine if status should transition to FullyMatched
    /// @param fillAmount The fill amount being applied
    /// @param remaining The remaining unfilled amount before this fill
    /// @return True if this fill will fully match the bet
    function willCompleteMatch(
        uint256 fillAmount,
        uint256 remaining
    ) internal pure returns (bool) {
        return fillAmount >= remaining;
    }

    // ============ State Update Helpers ============

    /// @notice Calculate new matched amount and remaining after a fill
    /// @dev Pure function that returns new state values without modifying storage
    /// @param currentMatchedAmount The current matched amount
    /// @param totalAmount The total bet amount
    /// @param fillAmount The amount being filled
    /// @return newMatchedAmount The updated matched amount
    /// @return newRemaining The updated remaining amount
    /// @return newStatus The new status as uint8
    function calculateFillResult(
        uint256 currentMatchedAmount,
        uint256 totalAmount,
        uint256 fillAmount
    ) internal pure returns (
        uint256 newMatchedAmount,
        uint256 newRemaining,
        uint8 newStatus
    ) {
        newMatchedAmount = currentMatchedAmount + fillAmount;
        newRemaining = totalAmount - newMatchedAmount;
        newStatus = newRemaining == 0 ? uint8(BetStatus.FullyMatched) : uint8(BetStatus.PartiallyMatched);
    }
}
