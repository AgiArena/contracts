// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AgiArenaCore
/// @notice Core betting contract that handles portfolio bets with off-chain JSON storage
/// @dev Implements the Morpho-style singleton pattern - immutable, no proxy, no upgradability
contract AgiArenaCore is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Custom Errors ============

    /// @notice Thrown when user has insufficient USDC balance
    /// @param required The required amount
    /// @param available The available balance
    error InsufficientBalance(uint256 required, uint256 available);

    /// @notice Thrown when bet hash is invalid (zero bytes32)
    error InvalidBetHash();

    /// @notice Thrown when bet has already been fully matched
    /// @param betId The bet ID that is already matched
    error BetAlreadyMatched(uint256 betId);

    /// @notice Thrown when bet does not exist
    /// @param betId The bet ID that was not found
    error BetNotFound(uint256 betId);

    /// @notice Thrown when caller is not authorized
    /// @param caller The unauthorized caller address
    error Unauthorized(address caller);

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when bet is not in pending status
    /// @param betId The bet ID that is not pending
    error BetNotPending(uint256 betId);

    /// @notice Thrown when fill amount exceeds remaining
    /// @param requested The requested fill amount
    /// @param remaining The remaining amount available
    error FillExceedsRemaining(uint256 requested, uint256 remaining);

    /// @notice Thrown when bet is fully matched and nothing to cancel
    /// @param betId The bet ID that is fully matched
    error NothingToCancel(uint256 betId);

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /// @notice Thrown when odds are invalid (zero)
    error InvalidOdds();

    /// @notice Thrown when creator tries to match their own bet
    error CannotMatchOwnBet();

    /// @notice Thrown when bet is not fully matched for settlement
    /// @param betId The bet ID that is not fully matched
    error BetNotFullyMatched(uint256 betId);

    /// @notice Thrown when bet is already settled
    /// @param betId The bet ID that is already settled
    error BetAlreadySettled(uint256 betId);

    /// @notice Thrown when caller is not the resolver
    /// @param caller The unauthorized caller address
    error NotResolver(address caller);

    /// @notice Thrown when bet has too many matchers for safe settlement
    /// @param matcherCount The number of matchers
    /// @param maxAllowed The maximum allowed
    error TooManyMatchers(uint256 matcherCount, uint256 maxAllowed);

    /// @notice Thrown when bet has no fills to distribute to
    error NoFillsToDistribute();

    // ============ Enums ============

    /// @notice Status of a bet through its lifecycle
    enum BetStatus {
        Pending, // Bet placed, waiting for matches
        PartiallyMatched, // Some amount filled
        FullyMatched, // All amount filled or remaining cancelled
        Cancelled, // Fully cancelled by creator (no fills existed)
        Settling, // Resolution in progress
        Settled // Final outcome determined by settleBet()
    }

    // ============ Structs ============

    /// @notice Core bet data structure with asymmetric odds support
    /// @dev Does NOT store individual market positions (too expensive on-chain)
    /// @dev oddsBps uses basis points: 10000 = 1.00x (even), 20000 = 2.00x, 5000 = 0.50x
    /// @dev requiredMatch = (creatorStake * ODDS_EVEN) / oddsBps
    struct Bet {
        bytes32 betHash; // keccak256 hash of portfolio JSON
        string jsonStorageRef; // Off-chain reference (e.g., "agent-1-bet-123")
        uint256 creatorStake; // Creator's USDC stake (6 decimals)
        uint256 requiredMatch; // Required matcher stake (calculated from odds)
        uint256 matchedAmount; // Amount filled by counter-parties
        uint32 oddsBps; // Odds in basis points (10000 = 1.00x, 20000 = 2.00x)
        address creator; // Bet creator address
        BetStatus status; // Current bet status
        uint256 createdAt; // Block timestamp when bet was placed
    }

    /// @notice Fill record for partial matches
    struct Fill {
        address filler; // Counter-party address
        uint256 amount; // Fill amount (6 decimals)
        uint256 filledAt; // Block timestamp when filled
    }

    // ============ State Variables ============

    /// @notice USDC token interface (immutable)
    IERC20 public immutable USDC;

    /// @notice Fee recipient address (immutable)
    /// @dev Fee collection implemented in settlement (Story 3.x)
    address public immutable FEE_RECIPIENT;

    /// @notice Platform fee in basis points (0.1% = 10 bps)
    /// @dev Fee collection implemented in settlement (Story 3.x)
    uint256 public constant PLATFORM_FEE_BPS = 10;

    /// @notice Basis points representing 1.00x odds (even money)
    /// @dev Used for odds calculations: requiredMatch = (creatorStake * ODDS_EVEN) / oddsBps
    uint32 public constant ODDS_EVEN = 10000;

    /// @notice Maximum number of matchers allowed per bet (gas limit protection)
    /// @dev Prevents gas exhaustion during settlement distribution
    uint256 public constant MAX_MATCHERS = 100;

    /// @notice Authorized resolver address (immutable)
    /// @dev Set in constructor, typically the ResolutionDAO contract
    address public immutable RESOLVER;

    /// @notice Counter for generating unique bet IDs
    uint256 public nextBetId;

    // ============ Modifiers ============

    /// @notice Validate odds are non-zero
    /// @param oddsBps The odds in basis points to validate
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
    /// @param betHash keccak256 hash of the portfolio JSON
    /// @param jsonStorageRef Off-chain storage reference
    /// @param creatorStake Creator's USDC stake (6 decimals)
    /// @param requiredMatch Required matcher stake (calculated from odds)
    /// @param oddsBps Odds in basis points (10000 = 1.00x, 20000 = 2.00x)
    event BetPlaced(
        uint256 indexed betId,
        address indexed creator,
        bytes32 betHash,
        string jsonStorageRef,
        uint256 creatorStake,
        uint256 requiredMatch,
        uint32 oddsBps
    );

    /// @notice Emitted when a bet is matched (full or partial)
    /// @param betId Unique identifier for the bet
    /// @param filler Address that filled the bet
    /// @param fillAmount Amount filled in this transaction
    /// @param remaining Amount still available for matching
    event BetMatched(uint256 indexed betId, address indexed filler, uint256 fillAmount, uint256 remaining);

    /// @notice Emitted when a bet is cancelled (full or partial)
    /// @param betId Unique identifier for the bet
    /// @param creator Address that created the bet
    /// @param refundAmount Amount of USDC refunded to creator
    event BetCancelled(uint256 indexed betId, address indexed creator, uint256 refundAmount);

    /// @notice Emitted when a bet is settled
    /// @param betId Unique identifier for the bet
    /// @param winner Address of the winner (address(0) if matchers won as a group)
    /// @param payout Total payout distributed (after fees)
    /// @param creatorWon True if creator won, false if matchers won
    event BetSettled(uint256 indexed betId, address indexed winner, uint256 payout, bool creatorWon);

    // ============ Constructor ============

    /// @notice Initialize the AgiArenaCore contract
    /// @param _usdc USDC token address on Base mainnet
    /// @param _feeRecipient Address to receive platform fees
    /// @param _resolver Authorized resolver address (typically ResolutionDAO)
    constructor(address _usdc, address _feeRecipient, address _resolver) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_resolver == address(0)) revert ZeroAddress();
        USDC = IERC20(_usdc);
        FEE_RECIPIENT = _feeRecipient;
        RESOLVER = _resolver;
    }

    // ============ External Functions ============

    /// @notice Place a portfolio bet with USDC escrow and custom odds
    /// @param betHash keccak256 hash of full portfolio JSON
    /// @param jsonStorageRef Reference to off-chain storage (database ID or IPFS hash)
    /// @param creatorStake Creator's USDC stake (6 decimals)
    /// @param oddsBps Odds in basis points (10000 = 1.00x even, 20000 = 2.00x)
    /// @return betId The unique identifier for this bet
    function placeBet(
        bytes32 betHash,
        string calldata jsonStorageRef,
        uint256 creatorStake,
        uint32 oddsBps
    )
        external
        nonReentrant
        validOdds(oddsBps)
        returns (uint256 betId)
    {
        // Validate inputs
        if (creatorStake == 0) revert ZeroAmount();
        if (betHash == bytes32(0)) revert InvalidBetHash();

        // Calculate required matcher stake based on odds
        // oddsBps = 20000 (2.00x) means matcher stakes creatorStake * 10000 / 20000 = 0.5x
        // oddsBps = 10000 (1.00x) means matcher stakes creatorStake * 10000 / 10000 = 1x (even)
        // oddsBps = 5000 (0.50x) means matcher stakes creatorStake * 10000 / 5000 = 2x
        uint256 requiredMatch = (creatorStake * ODDS_EVEN) / oddsBps;
        if (requiredMatch == 0) revert ZeroAmount(); // Prevent dust bets

        // Check user has sufficient balance before state changes
        uint256 userBalance = USDC.balanceOf(msg.sender);
        if (userBalance < creatorStake) revert InsufficientBalance(creatorStake, userBalance);

        // Check-Effects-Interactions: Update state before external call
        betId = nextBetId++;

        bets[betId] = Bet({
            betHash: betHash,
            jsonStorageRef: jsonStorageRef,
            creatorStake: creatorStake,
            requiredMatch: requiredMatch,
            matchedAmount: 0,
            oddsBps: oddsBps,
            creator: msg.sender,
            status: BetStatus.Pending,
            createdAt: block.timestamp
        });

        // Transfer USDC from sender to contract (external call last)
        USDC.safeTransferFrom(msg.sender, address(this), creatorStake);

        emit BetPlaced(betId, msg.sender, betHash, jsonStorageRef, creatorStake, requiredMatch, oddsBps);
    }

    /// @notice Match a bet (full or partial fill)
    /// @dev Counter-party gets the opposite portfolio position
    /// @param betId The bet ID to match
    /// @param fillAmount The amount to fill (can be partial) against requiredMatch
    function matchBet(uint256 betId, uint256 fillAmount) external nonReentrant {
        // Load bet from storage
        Bet storage bet = bets[betId];

        // Validate bet exists
        if (bet.creator == address(0)) revert BetNotFound(betId);

        // Prevent self-matching (wash trading prevention)
        if (bet.creator == msg.sender) revert CannotMatchOwnBet();

        // Validate bet status allows matching
        if (bet.status != BetStatus.Pending && bet.status != BetStatus.PartiallyMatched) {
            revert BetNotPending(betId);
        }

        // Validate fill amount
        if (fillAmount == 0) revert ZeroAmount();

        // Calculate remaining against requiredMatch (not creatorStake)
        uint256 remaining = bet.requiredMatch - bet.matchedAmount;
        if (fillAmount > remaining) revert FillExceedsRemaining(fillAmount, remaining);

        // Check filler has sufficient balance
        uint256 fillerBalance = USDC.balanceOf(msg.sender);
        if (fillerBalance < fillAmount) revert InsufficientBalance(fillAmount, fillerBalance);

        // Check MAX_MATCHERS limit to prevent gas exhaustion during settlement
        uint256 currentFillCount = betFills[betId].length;
        if (currentFillCount >= MAX_MATCHERS) revert TooManyMatchers(currentFillCount + 1, MAX_MATCHERS);

        // Check-Effects-Interactions: Update state before external call
        bet.matchedAmount += fillAmount;

        // Record fill
        betFills[betId].push(Fill({ filler: msg.sender, amount: fillAmount, filledAt: block.timestamp }));

        // Update status - fully matched when matchedAmount == requiredMatch
        if (bet.matchedAmount == bet.requiredMatch) {
            bet.status = BetStatus.FullyMatched;
        } else {
            bet.status = BetStatus.PartiallyMatched;
        }

        uint256 newRemaining = bet.requiredMatch - bet.matchedAmount;

        // Transfer USDC from filler to contract (external call last)
        USDC.safeTransferFrom(msg.sender, address(this), fillAmount);

        emit BetMatched(betId, msg.sender, fillAmount, newRemaining);
    }

    /// @notice Cancel a bet and return unfilled USDC to creator
    /// @dev Can cancel fully unmatched bets OR cancel remaining unfilled portion of partial bets
    /// @dev For asymmetric odds: refunds creator's unmatched stake proportionally
    /// @param betId The bet ID to cancel
    function cancelBet(uint256 betId) external nonReentrant {
        // Load bet from storage
        Bet storage bet = bets[betId];

        // Validate bet exists
        if (bet.creator == address(0)) revert BetNotFound(betId);

        // Validate caller is creator
        if (bet.creator != msg.sender) revert Unauthorized(msg.sender);

        // Validate bet status allows cancellation (Pending or PartiallyMatched)
        if (bet.status != BetStatus.Pending && bet.status != BetStatus.PartiallyMatched) {
            revert BetNotPending(betId);
        }

        // Calculate refund amount based on unmatched portion of requiredMatch
        // Creator gets back their stake proportional to what wasn't matched
        // If 50% matched, creator gets back 50% of their stake
        uint256 unmatchedRatio = bet.requiredMatch - bet.matchedAmount;
        uint256 refundAmount = (bet.creatorStake * unmatchedRatio) / bet.requiredMatch;

        // Validate there's something to cancel
        if (refundAmount == 0) revert NothingToCancel(betId);

        // Check-Effects-Interactions: Update state before external call
        if (bet.matchedAmount == 0) {
            // No fills - full cancellation
            bet.status = BetStatus.Cancelled;
        } else {
            // Has fills - close remaining to new matches (treated as fully matched)
            bet.status = BetStatus.FullyMatched;
        }

        // Return unfilled USDC to creator (external call last)
        USDC.safeTransfer(msg.sender, refundAmount);

        emit BetCancelled(betId, msg.sender, refundAmount);
    }

    /// @notice Settle a bet and distribute funds based on outcome
    /// @dev Only callable by authorized resolver (ResolutionDAO)
    /// @dev Distributes total pot (creatorStake + matchedAmount) minus platform fee
    /// @param betId The bet ID to settle
    /// @param creatorWins True if creator's portfolio wins, false if matchers win
    function settleBet(uint256 betId, bool creatorWins) external nonReentrant onlyResolver {
        // Load bet from storage
        Bet storage bet = bets[betId];

        // Validate bet exists
        if (bet.creator == address(0)) revert BetNotFound(betId);

        // Validate bet is fully matched (required for settlement)
        if (bet.status == BetStatus.Settled) revert BetAlreadySettled(betId);
        if (bet.status != BetStatus.FullyMatched) revert BetNotFullyMatched(betId);

        // Calculate total pot and fees
        // Total pot = creator's stake + all matcher stakes
        uint256 totalPot = bet.creatorStake + bet.matchedAmount;

        // Platform fee: 0.1% (10 bps) of total pot
        uint256 platformFee = (totalPot * PLATFORM_FEE_BPS) / 10000;

        // Distributable payout after fee deduction
        uint256 payout = totalPot - platformFee;

        // Check-Effects-Interactions: Update state before external calls
        bet.status = BetStatus.Settled;

        // Transfer platform fee to fee recipient
        if (platformFee > 0) {
            USDC.safeTransfer(FEE_RECIPIENT, platformFee);
        }

        // Distribute payout based on outcome
        if (creatorWins) {
            // Creator wins: single transfer of entire payout to creator
            USDC.safeTransfer(bet.creator, payout);
            emit BetSettled(betId, bet.creator, payout, true);
        } else {
            // Matchers win: distribute proportionally to all matchers
            _distributeToMatchers(betId, payout, bet.matchedAmount);
            emit BetSettled(betId, address(0), payout, false);
        }
    }

    // ============ Internal Functions ============

    /// @notice Distribute winnings to matchers proportionally based on their fill amounts
    /// @dev Uses "last matcher gets remainder" pattern to handle rounding
    /// @param betId The bet ID to distribute for
    /// @param totalPayout Total payout to distribute (after fees)
    /// @param totalMatched Total amount matched (sum of all fills)
    function _distributeToMatchers(uint256 betId, uint256 totalPayout, uint256 totalMatched) internal {
        Fill[] storage fills = betFills[betId];
        uint256 fillCount = fills.length;

        // Safety check - should never happen due to FullyMatched status requirement
        if (fillCount == 0) revert NoFillsToDistribute();

        // Track distributed amount for rounding handling
        uint256 distributed = 0;

        // Distribute to all matchers except the last one
        for (uint256 i = 0; i < fillCount - 1; i++) {
            // Calculate proportional payout: (totalPayout * fillAmount) / totalMatched
            uint256 matcherPayout = (totalPayout * fills[i].amount) / totalMatched;
            USDC.safeTransfer(fills[i].filler, matcherPayout);
            distributed += matcherPayout;
        }

        // Last matcher gets the remainder (handles rounding dust)
        uint256 lastMatcherPayout = totalPayout - distributed;
        USDC.safeTransfer(fills[fillCount - 1].filler, lastMatcherPayout);
    }

    // ============ View Functions ============

    /// @notice Get full bet state for a given bet ID
    /// @param betId The bet ID to query
    /// @return The Bet struct containing all bet data
    function getBetState(uint256 betId) external view returns (Bet memory) {
        Bet storage bet = bets[betId];
        if (bet.creator == address(0)) revert BetNotFound(betId);
        return bet;
    }

    /// @notice Get all fills for a bet
    /// @param betId The bet ID to query
    /// @return Array of Fill structs
    function getBetFills(uint256 betId) external view returns (Fill[] memory) {
        return betFills[betId];
    }

    /// @notice Get the number of fills for a bet
    /// @param betId The bet ID to query
    /// @return Number of fills
    function getBetFillCount(uint256 betId) external view returns (uint256) {
        return betFills[betId].length;
    }
}
