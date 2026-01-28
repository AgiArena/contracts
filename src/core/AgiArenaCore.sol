// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AgiArenaCore
/// @notice Core betting contract for multi-source category betting with snapshot verification
/// @dev Implements the Morpho-style singleton pattern - immutable, no proxy, no upgradability
/// @dev CLEAN BREAK v2: Uses bitmap-based hash verification: tradesHash = keccak256(snapshotId + positionBitmap)
contract AgiArenaCore is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Custom Errors ============

    /// @notice Thrown when user has insufficient collateral balance
    error InsufficientBalance(uint256 required, uint256 available);

    /// @notice Thrown when bet hash is invalid (zero bytes32)
    error InvalidBetHash();

    /// @notice Thrown when snapshot ID is invalid (zero bytes32)
    error InvalidSnapshotId();

    /// @notice Thrown when bet has already been fully matched
    error BetAlreadyMatched(uint256 betId);

    /// @notice Thrown when bet does not exist
    error BetNotFound(uint256 betId);

    /// @notice Thrown when caller is not authorized
    error Unauthorized(address caller);

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when bet is not in pending status
    error BetNotPending(uint256 betId);

    /// @notice Thrown when fill amount exceeds remaining
    error FillExceedsRemaining(uint256 requested, uint256 remaining);

    /// @notice Thrown when bet is fully matched and nothing to cancel
    error NothingToCancel(uint256 betId);

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /// @notice Thrown when odds are invalid (zero)
    error InvalidOdds();

    /// @notice Thrown when creator tries to match their own bet
    error CannotMatchOwnBet();

    /// @notice Thrown when bet is not fully matched for settlement
    error BetNotFullyMatched(uint256 betId);

    /// @notice Thrown when bet is already settled
    error BetAlreadySettled(uint256 betId);

    /// @notice Thrown when caller is not the resolver
    error NotResolver(address caller);

    /// @notice Thrown when bet has too many matchers for safe settlement
    error TooManyMatchers(uint256 matcherCount, uint256 maxAllowed);

    /// @notice Thrown when bet has no fills to distribute to
    error NoFillsToDistribute();

    /// @notice Thrown when resolution deadline is not in the future
    error DeadlineMustBeFuture();

    /// @notice Thrown when bet has expired (deadline passed)
    error BetExpired(uint256 betId);

    /// @notice Thrown when batch size exceeds maximum
    error BatchTooLarge(uint256 requested, uint256 max);

    /// @notice Thrown when batch arrays have mismatched lengths
    error BatchLengthMismatch();

    // ============ Enums ============

    /// @notice Status of a bet through its lifecycle
    enum BetStatus {
        Pending,          // Bet placed, waiting for matches
        PartiallyMatched, // Some amount filled
        FullyMatched,     // All amount filled or remaining cancelled
        Cancelled,        // Fully cancelled by creator (no fills existed)
        Settling,         // Resolution in progress
        Settled           // Final outcome determined by settleBet()
    }

    // ============ Structs ============

    /// @notice Core bet data structure with bitmap-based verification
    /// @dev tradesHash = keccak256(abi.encodePacked(snapshotId, positionBitmap))
    /// @dev snapshotId = snapshot identifier string (e.g., "crypto-2026-01-26-12-30")
    /// @dev positionBitmap stored off-chain, tradesHash verifies commitment
    struct Bet {
        bytes32 tradesHash;        // keccak256(snapshotId + positionBitmap) - computed on-chain
        string snapshotId;         // Snapshot ID string (links bet to standardized trade list)
        string jsonStorageRef;     // Off-chain reference for bitmap storage
        uint256 creatorStake;      // Creator's collateral stake (token decimals vary)
        uint256 requiredMatch;     // Required matcher stake (calculated from odds)
        uint256 matchedAmount;     // Amount filled by counter-parties
        uint32 oddsBps;            // Odds in basis points (10000 = 1.00x, 20000 = 2.00x)
        address creator;           // Bet creator address
        BetStatus status;          // Current bet status
        uint256 createdAt;         // Block timestamp when bet was placed
        uint256 resolutionDeadline;// Unix timestamp when bet can be resolved
    }

    /// @notice Fill record for partial matches
    struct Fill {
        address filler;    // Counter-party address
        uint256 amount;    // Fill amount (token decimals vary)
        uint256 filledAt;  // Block timestamp when filled
    }

    // ============ State Variables ============

    /// @notice Collateral token interface (immutable)
    IERC20 public immutable COLLATERAL_TOKEN;

    /// @notice Collateral token decimals (cached for gas efficiency)
    uint8 public immutable COLLATERAL_DECIMALS;

    /// @notice Collateral token symbol (for display purposes)
    string public COLLATERAL_SYMBOL;

    /// @notice Fee recipient address (immutable)
    address public immutable FEE_RECIPIENT;

    /// @notice Platform fee in basis points (0.1% = 10 bps)
    uint256 public constant PLATFORM_FEE_BPS = 10;

    /// @notice Basis points representing 1.00x odds (even money)
    uint32 public constant ODDS_EVEN = 10000;

    /// @notice Maximum number of matchers allowed per bet (gas limit protection)
    uint256 public constant MAX_MATCHERS = 100;

    /// @notice Maximum batch size for batch operations (gas limit protection)
    uint256 public constant MAX_BATCH_SIZE = 50;

    /// @notice Authorized resolver address (immutable)
    address public immutable RESOLVER;

    /// @notice Counter for generating unique bet IDs
    uint256 public nextBetId;

    // ============ Modifiers ============

    /// @notice Validate odds are non-zero
    modifier validOdds(uint32 oddsBps) {
        if (oddsBps == 0) revert InvalidOdds();
        _;
    }

    /// @notice Only authorized resolver can call
    modifier onlyResolver() {
        if (msg.sender != RESOLVER) revert NotResolver(msg.sender);
        _;
    }

    /// @notice Mapping of bet ID to Bet struct
    mapping(uint256 => Bet) public bets;

    /// @notice Mapping of bet ID to array of fills
    mapping(uint256 => Fill[]) public betFills;

    // ============ Events ============

    /// @notice Emitted when a new bet is placed
    /// @param betId Unique identifier for the bet
    /// @param creator Address that placed the bet
    /// @param tradesHash keccak256(snapshotId + positionBitmap) - computed on-chain
    /// @param snapshotId Snapshot ID string (links bet to standardized trade list)
    /// @param jsonStorageRef Off-chain storage reference for bitmap
    /// @param creatorStake Creator's collateral stake
    /// @param requiredMatch Required matcher stake (calculated from odds)
    /// @param oddsBps Odds in basis points (10000 = 1.00x, 20000 = 2.00x)
    /// @param resolutionDeadline Unix timestamp when bet can be resolved
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

    /// @notice Emitted when a bet is matched (full or partial)
    event BetMatched(uint256 indexed betId, address indexed filler, uint256 fillAmount, uint256 remaining);

    /// @notice Emitted when a bet is cancelled (full or partial)
    event BetCancelled(uint256 indexed betId, address indexed creator, uint256 refundAmount);

    /// @notice Emitted when a bet is settled
    event BetSettled(uint256 indexed betId, address indexed winner, uint256 payout, bool creatorWon);

    /// @notice Emitted when an expired bet is auto-expired
    event BetAutoExpired(uint256 indexed betId, address indexed creator, uint256 refundAmount, bool hadFills);

    // ============ Constructor ============

    /// @notice Initialize the AgiArenaCore contract
    /// @param _collateralToken Collateral token address
    /// @param _feeRecipient Address to receive platform fees
    /// @param _resolver Authorized resolver address (typically ResolutionDAO)
    constructor(address _collateralToken, address _feeRecipient, address _resolver) {
        if (_collateralToken == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_resolver == address(0)) revert ZeroAddress();
        COLLATERAL_TOKEN = IERC20(_collateralToken);
        COLLATERAL_DECIMALS = IERC20Metadata(_collateralToken).decimals();
        COLLATERAL_SYMBOL = IERC20Metadata(_collateralToken).symbol();
        FEE_RECIPIENT = _feeRecipient;
        RESOLVER = _resolver;
    }

    // ============ External Functions ============

    /// @notice Place a bet with bitmap-based hash verification
    /// @param snapshotId Snapshot ID string (e.g., "crypto-2026-01-26-12-30")
    /// @param positionBitmap Compact position encoding (1 bit per trade: LONG=1, SHORT=0)
    /// @param jsonStorageRef Reference to off-chain storage (database ID for full trade details)
    /// @param creatorStake Creator's collateral stake (token decimals vary by chain)
    /// @param oddsBps Odds in basis points (10000 = 1.00x even, 20000 = 2.00x)
    /// @param resolutionDeadline Unix timestamp when bet can be resolved (must be in future)
    /// @return betId The unique identifier for this bet
    function placeBet(
        string calldata snapshotId,
        bytes calldata positionBitmap,
        string calldata jsonStorageRef,
        uint256 creatorStake,
        uint32 oddsBps,
        uint256 resolutionDeadline
    )
        external
        nonReentrant
        validOdds(oddsBps)
        returns (uint256 betId)
    {
        // Validate inputs
        if (creatorStake == 0) revert ZeroAmount();
        if (bytes(snapshotId).length == 0) revert InvalidSnapshotId();
        if (positionBitmap.length == 0) revert InvalidBetHash();
        if (resolutionDeadline <= block.timestamp) revert DeadlineMustBeFuture();

        // Compute tradesHash on-chain: keccak256(snapshotId + positionBitmap)
        bytes32 tradesHash = keccak256(abi.encodePacked(snapshotId, positionBitmap));

        // Calculate required matcher stake based on odds
        uint256 requiredMatch = (creatorStake * ODDS_EVEN) / oddsBps;
        if (requiredMatch == 0) revert ZeroAmount();

        // Check user has sufficient balance
        uint256 userBalance = COLLATERAL_TOKEN.balanceOf(msg.sender);
        if (userBalance < creatorStake) revert InsufficientBalance(creatorStake, userBalance);

        // Check-Effects-Interactions: Update state before external call
        betId = nextBetId++;

        bets[betId] = Bet({
            tradesHash: tradesHash,
            snapshotId: snapshotId,
            jsonStorageRef: jsonStorageRef,
            creatorStake: creatorStake,
            requiredMatch: requiredMatch,
            matchedAmount: 0,
            oddsBps: oddsBps,
            creator: msg.sender,
            status: BetStatus.Pending,
            createdAt: block.timestamp,
            resolutionDeadline: resolutionDeadline
        });

        // Transfer collateral from sender to contract
        COLLATERAL_TOKEN.safeTransferFrom(msg.sender, address(this), creatorStake);

        emit BetPlaced(
            betId,
            msg.sender,
            tradesHash,
            snapshotId,
            jsonStorageRef,
            creatorStake,
            requiredMatch,
            oddsBps,
            resolutionDeadline
        );
    }

    /// @notice Match a bet (full or partial fill)
    /// @dev Matcher implicitly accepts the bet's snapshotId by matching it
    /// @param betId The bet ID to match
    /// @param fillAmount The amount to fill (can be partial) against requiredMatch
    function matchBet(uint256 betId, uint256 fillAmount) external nonReentrant {
        Bet storage bet = bets[betId];

        if (bet.creator == address(0)) revert BetNotFound(betId);
        if (bet.creator == msg.sender) revert CannotMatchOwnBet();
        if (block.timestamp >= bet.resolutionDeadline) revert BetExpired(betId);

        if (bet.status != BetStatus.Pending && bet.status != BetStatus.PartiallyMatched) {
            revert BetNotPending(betId);
        }

        if (fillAmount == 0) revert ZeroAmount();

        uint256 remaining = bet.requiredMatch - bet.matchedAmount;
        if (fillAmount > remaining) revert FillExceedsRemaining(fillAmount, remaining);

        uint256 fillerBalance = COLLATERAL_TOKEN.balanceOf(msg.sender);
        if (fillerBalance < fillAmount) revert InsufficientBalance(fillAmount, fillerBalance);

        uint256 currentFillCount = betFills[betId].length;
        if (currentFillCount >= MAX_MATCHERS) revert TooManyMatchers(currentFillCount + 1, MAX_MATCHERS);

        bet.matchedAmount += fillAmount;
        betFills[betId].push(Fill({ filler: msg.sender, amount: fillAmount, filledAt: block.timestamp }));

        if (bet.matchedAmount == bet.requiredMatch) {
            bet.status = BetStatus.FullyMatched;
        } else {
            bet.status = BetStatus.PartiallyMatched;
        }

        uint256 newRemaining = bet.requiredMatch - bet.matchedAmount;

        COLLATERAL_TOKEN.safeTransferFrom(msg.sender, address(this), fillAmount);

        emit BetMatched(betId, msg.sender, fillAmount, newRemaining);
    }

    /// @notice Cancel a bet and return unfilled collateral to creator
    /// @param betId The bet ID to cancel
    function cancelBet(uint256 betId) external nonReentrant {
        Bet storage bet = bets[betId];

        if (bet.creator == address(0)) revert BetNotFound(betId);
        if (bet.creator != msg.sender) revert Unauthorized(msg.sender);

        if (bet.status != BetStatus.Pending && bet.status != BetStatus.PartiallyMatched) {
            revert BetNotPending(betId);
        }

        uint256 unmatchedRatio = bet.requiredMatch - bet.matchedAmount;
        uint256 refundAmount = (bet.creatorStake * unmatchedRatio) / bet.requiredMatch;

        if (refundAmount == 0) revert NothingToCancel(betId);

        if (bet.matchedAmount == 0) {
            bet.status = BetStatus.Cancelled;
        } else {
            bet.status = BetStatus.FullyMatched;
        }

        COLLATERAL_TOKEN.safeTransfer(msg.sender, refundAmount);

        emit BetCancelled(betId, msg.sender, refundAmount);
    }

    /// @notice Settle a bet and distribute funds based on outcome
    /// @dev Only callable by authorized resolver (ResolutionDAO)
    /// @param betId The bet ID to settle
    /// @param creatorWins True if creator's portfolio wins, false if matchers win
    function settleBet(uint256 betId, bool creatorWins) external nonReentrant onlyResolver {
        _settleBetInternal(betId, creatorWins);
    }

    /// @notice Batch settle multiple bets in one transaction
    /// @param betIds Array of bet IDs to settle
    /// @param creatorWins Array of outcome flags
    function settleBets(uint256[] calldata betIds, bool[] calldata creatorWins) external nonReentrant onlyResolver {
        if (betIds.length != creatorWins.length) revert BatchLengthMismatch();
        if (betIds.length > MAX_BATCH_SIZE) revert BatchTooLarge(betIds.length, MAX_BATCH_SIZE);

        for (uint256 i = 0; i < betIds.length; i++) {
            _settleBetInternalSafe(betIds[i], creatorWins[i]);
        }
    }

    /// @notice Permissionless function to expire unmatched/partial bets past deadline
    /// @param betIds Array of bet IDs to expire
    function expireBets(uint256[] calldata betIds) external nonReentrant {
        if (betIds.length > MAX_BATCH_SIZE) revert BatchTooLarge(betIds.length, MAX_BATCH_SIZE);

        for (uint256 i = 0; i < betIds.length; i++) {
            _expireBetIfNeeded(betIds[i]);
        }
    }

    function _settleBetInternal(uint256 betId, bool creatorWins) internal {
        Bet storage bet = bets[betId];

        if (bet.creator == address(0)) revert BetNotFound(betId);
        if (bet.status == BetStatus.Settled) revert BetAlreadySettled(betId);

        if (bet.status == BetStatus.Pending || bet.status == BetStatus.PartiallyMatched) {
            if (block.timestamp >= bet.resolutionDeadline) {
                _autoExpire(betId);
            }
        }

        if (bet.status == BetStatus.Cancelled) {
            return;
        }

        if (bet.status != BetStatus.FullyMatched) revert BetNotFullyMatched(betId);

        uint256 totalPot = bet.creatorStake + bet.matchedAmount;
        uint256 platformFee = (totalPot * PLATFORM_FEE_BPS) / 10000;
        uint256 payout = totalPot - platformFee;

        bet.status = BetStatus.Settled;

        if (platformFee > 0) {
            COLLATERAL_TOKEN.safeTransfer(FEE_RECIPIENT, platformFee);
        }

        if (creatorWins) {
            COLLATERAL_TOKEN.safeTransfer(bet.creator, payout);
            emit BetSettled(betId, bet.creator, payout, true);
        } else {
            _distributeToMatchers(betId, payout, bet.matchedAmount);
            emit BetSettled(betId, address(0), payout, false);
        }
    }

    function _settleBetInternalSafe(uint256 betId, bool creatorWins) internal {
        Bet storage bet = bets[betId];

        if (bet.creator == address(0)) return;
        if (bet.status == BetStatus.Settled) return;
        if (bet.status == BetStatus.Cancelled) return;

        if (bet.status == BetStatus.Pending || bet.status == BetStatus.PartiallyMatched) {
            if (block.timestamp >= bet.resolutionDeadline) {
                _autoExpire(betId);
            }
        }

        if (bet.status == BetStatus.Cancelled) return;
        if (bet.status != BetStatus.FullyMatched) return;

        uint256 totalPot = bet.creatorStake + bet.matchedAmount;
        uint256 platformFee = (totalPot * PLATFORM_FEE_BPS) / 10000;
        uint256 payout = totalPot - platformFee;

        bet.status = BetStatus.Settled;

        if (platformFee > 0) {
            COLLATERAL_TOKEN.safeTransfer(FEE_RECIPIENT, platformFee);
        }

        if (creatorWins) {
            COLLATERAL_TOKEN.safeTransfer(bet.creator, payout);
            emit BetSettled(betId, bet.creator, payout, true);
        } else {
            _distributeToMatchers(betId, payout, bet.matchedAmount);
            emit BetSettled(betId, address(0), payout, false);
        }
    }

    function _autoExpire(uint256 betId) internal {
        Bet storage bet = bets[betId];

        if (bet.status != BetStatus.Pending && bet.status != BetStatus.PartiallyMatched) {
            return;
        }

        uint256 unmatchedRatio = bet.requiredMatch - bet.matchedAmount;
        uint256 refundAmount = (bet.creatorStake * unmatchedRatio) / bet.requiredMatch;

        bool hadFills = bet.matchedAmount > 0;

        if (hadFills) {
            bet.status = BetStatus.FullyMatched;
        } else {
            bet.status = BetStatus.Cancelled;
        }

        if (refundAmount > 0) {
            COLLATERAL_TOKEN.safeTransfer(bet.creator, refundAmount);
        }

        emit BetAutoExpired(betId, bet.creator, refundAmount, hadFills);
    }

    function _expireBetIfNeeded(uint256 betId) internal {
        Bet storage bet = bets[betId];

        if (bet.creator == address(0)) return;
        if (bet.status != BetStatus.Pending && bet.status != BetStatus.PartiallyMatched) return;
        if (block.timestamp < bet.resolutionDeadline) return;

        _autoExpire(betId);
    }

    // ============ Internal Functions ============

    function _distributeToMatchers(uint256 betId, uint256 totalPayout, uint256 totalMatched) internal {
        Fill[] storage fills = betFills[betId];
        uint256 fillCount = fills.length;

        if (fillCount == 0) revert NoFillsToDistribute();

        uint256 distributed = 0;

        for (uint256 i = 0; i < fillCount - 1; i++) {
            uint256 matcherPayout = (totalPayout * fills[i].amount) / totalMatched;
            COLLATERAL_TOKEN.safeTransfer(fills[i].filler, matcherPayout);
            distributed += matcherPayout;
        }

        uint256 lastMatcherPayout = totalPayout - distributed;
        COLLATERAL_TOKEN.safeTransfer(fills[fillCount - 1].filler, lastMatcherPayout);
    }

    // ============ View Functions ============

    /// @notice Compute tradesHash from snapshotId and positionBitmap
    /// @dev Pure function for off-chain verification. Same computation as used in placeBet.
    /// @param snapshotId Snapshot ID string
    /// @param positionBitmap Position bitmap bytes (1 bit per trade)
    /// @return The keccak256 hash of the packed data
    function computeTradesHash(
        string calldata snapshotId,
        bytes calldata positionBitmap
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(snapshotId, positionBitmap));
    }

    /// @notice Get full bet state for a given bet ID
    function getBetState(uint256 betId) external view returns (Bet memory) {
        Bet storage bet = bets[betId];
        if (bet.creator == address(0)) revert BetNotFound(betId);
        return bet;
    }

    /// @notice Get all fills for a bet
    function getBetFills(uint256 betId) external view returns (Fill[] memory) {
        return betFills[betId];
    }

    /// @notice Get the number of fills for a bet
    function getBetFillCount(uint256 betId) external view returns (uint256) {
        return betFills[betId].length;
    }

    /// @notice Get the resolution deadline for a bet
    function getBetDeadline(uint256 betId) external view returns (uint256) {
        return bets[betId].resolutionDeadline;
    }
}
