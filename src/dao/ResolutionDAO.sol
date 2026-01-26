// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IAgiArenaCore
/// @notice Interface for AgiArenaCore bet data access
interface IAgiArenaCore {
    /// @notice Bet status enum matching AgiArenaCore
    enum BetStatus {
        Pending,
        PartiallyMatched,
        FullyMatched,
        Cancelled,
        Settling,
        Settled
    }

    /// @notice Bet struct matching AgiArenaCore (with odds support)
    struct Bet {
        bytes32 betHash;
        string jsonStorageRef;
        uint256 creatorStake;      // Creator's collateral stake (decimals vary)
        uint256 requiredMatch;     // Required matcher stake (calculated from odds)
        uint256 matchedAmount;
        uint32 oddsBps;            // Odds in basis points (10000 = 1.00x)
        address creator;
        BetStatus status;
        uint256 createdAt;
    }

    /// @notice Fill struct matching AgiArenaCore
    struct Fill {
        address filler;
        uint256 amount;
        uint256 filledAt;
    }

    /// @notice Get bet data by ID (with odds support)
    function bets(uint256 betId) external view returns (
        bytes32 betHash,
        string memory jsonStorageRef,
        uint256 creatorStake,
        uint256 requiredMatch,
        uint256 matchedAmount,
        uint32 oddsBps,
        address creator,
        BetStatus status,
        uint256 createdAt
    );

    /// @notice Get all fills for a bet
    function getBetFills(uint256 betId) external view returns (Fill[] memory);

    /// @notice Get the collateral token address
    function COLLATERAL_TOKEN() external view returns (IERC20);

    /// @notice Get the fee recipient address
    function FEE_RECIPIENT() external view returns (address);
}

/// @title ResolutionDAO
/// @notice Keeper DAO contract with IP discovery for keeper coordination, portfolio score voting, and permissionless settlement
/// @dev Implements fully decentralized governance - NO admin functions
contract ResolutionDAO is ReentrancyGuard {
    using SafeERC20 for IERC20;
    // ============ Custom Errors ============

    /// @notice Thrown when caller is not an authorized keeper
    /// @param caller The unauthorized caller address
    error UnauthorizedKeeper(address caller);

    /// @notice Thrown when proposal does not exist
    /// @param proposalId The proposal ID that was not found
    error ProposalNotFound(uint256 proposalId);

    /// @notice Thrown when proposal has already been executed
    /// @param proposalId The proposal ID that was already executed
    error ProposalAlreadyExecuted(uint256 proposalId);

    /// @notice Thrown when proposal has expired
    /// @param proposalId The proposal ID that has expired
    error ProposalExpired(uint256 proposalId);

    /// @notice Thrown when keeper already exists
    /// @param keeper The keeper address that already exists
    error KeeperAlreadyExists(address keeper);

    /// @notice Thrown when keeper does not exist
    /// @param keeper The keeper address that was not found
    error KeeperNotFound(address keeper);

    /// @notice Thrown when keeper has already voted on a bet
    /// @param keeper The keeper address
    /// @param betId The bet ID
    error AlreadyVoted(address keeper, uint256 betId);

    /// @notice Thrown when score is out of valid range
    /// @param score The invalid score
    error InvalidScore(int256 score);

    /// @notice Thrown when keeper has already voted on a proposal
    /// @param keeper The keeper address
    /// @param proposalId The proposal ID
    error AlreadyVotedOnProposal(address keeper, uint256 proposalId);

    /// @notice Thrown when quorum not reached for proposal execution
    /// @param proposalId The proposal ID
    error QuorumNotReached(uint256 proposalId);

    /// @notice Thrown when trying to propose self as keeper
    error CannotProposeSelf();

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /// @notice Thrown when IP address is empty
    error EmptyIPAddress();

    /// @notice Thrown when trying to remove last keeper
    error CannotRemoveLastKeeper();

    // ============ Settlement Custom Errors (Story 3.3) ============

    /// @notice Thrown when trying to settle a bet without keeper consensus
    /// @param betId The bet ID that lacks consensus
    error ConsensusNotReached(uint256 betId);

    /// @notice Thrown when trying to settle a bet that has already been settled
    /// @param betId The bet ID that was already settled
    error BetAlreadySettled(uint256 betId);

    /// @notice Thrown when caller is not the winner trying to claim winnings
    /// @param caller The unauthorized caller address
    /// @param betId The bet ID
    error NotWinner(address caller, uint256 betId);

    /// @notice Thrown when no winnings are available to claim
    /// @param betId The bet ID with no winnings
    error NoWinningsAvailable(uint256 betId);

    /// @notice Thrown when bet status is invalid for the operation
    /// @param betId The bet ID with invalid status
    error InvalidBetStatus(uint256 betId);

    /// @notice Thrown when bet has no filler (cannot settle without counter-party)
    /// @param betId The bet ID with no filler
    error NoFiller(uint256 betId);

    // ============ Dispute Custom Errors (Story 3.4) ============

    /// @notice Thrown when dispute window has expired
    /// @param betId The bet ID
    /// @param consensusAt When consensus was reached
    /// @param deadline When the dispute window closed
    error DisputeWindowExpired(uint256 betId, uint256 consensusAt, uint256 deadline);

    /// @notice Thrown when a dispute has already been raised for this bet
    /// @param betId The bet ID that is already disputed
    error DisputeAlreadyRaised(uint256 betId);

    /// @notice Thrown when no dispute exists for this bet
    /// @param betId The bet ID with no dispute
    error DisputeNotFound(uint256 betId);

    /// @notice Thrown when dispute stake is below minimum required
    /// @param provided The amount provided
    /// @param required The minimum required amount
    error InsufficientDisputeStake(uint256 provided, uint256 required);

    /// @notice Thrown when dispute reason is empty
    error DisputeReasonRequired();

    /// @notice Thrown when trying to settle a bet with unresolved dispute
    /// @param betId The bet ID with pending dispute
    error DisputePending(uint256 betId);

    /// @notice Thrown when dispute is already resolved
    /// @param betId The bet ID with already resolved dispute
    error DisputeAlreadyResolved(uint256 betId);

    /// @notice Thrown when keeper has already been slashed for this bet
    /// @param keeper The keeper address
    /// @param betId The bet ID
    error KeeperAlreadySlashed(address keeper, uint256 betId);

    /// @notice Thrown when bet is not disputed
    /// @param betId The bet ID that is not disputed
    error BetNotDisputed(uint256 betId);

    /// @notice Thrown when dispute outcome did not change (for refund)
    /// @param betId The bet ID
    error DisputeOutcomeUnchanged(uint256 betId);

    /// @notice Thrown when dispute outcome did change (for slash)
    /// @param betId The bet ID
    error DisputeOutcomeChanged(uint256 betId);

    /// @notice Thrown when disputer stake has already been processed
    /// @param betId The bet ID
    error DisputeStakeAlreadyProcessed(uint256 betId);

    /// @notice Thrown when dispute reason exceeds maximum length
    /// @param length The provided reason length
    /// @param maxLength The maximum allowed length
    error DisputeReasonTooLong(uint256 length, uint256 maxLength);

    // ============ Constants ============

    /// @notice Proposal expiry duration (7 days)
    uint256 public constant PROPOSAL_EXPIRY = 7 days;

    /// @notice Score range: -10000 to +10000 (±100% in basis points)
    int256 public constant MIN_SCORE = -10000;
    int256 public constant MAX_SCORE = 10000;

    /// @notice Default tolerance for score divergence detection (100 bps = 1%)
    /// @dev Used in _checkConsensus to emit ScoreDivergence when scores differ significantly
    uint256 public constant DEFAULT_TOLERANCE_BPS = 100;

    /// @notice Platform fee in basis points (0.1% = 10 bps)
    /// @dev Hardcoded per Story 3.3 AC 7
    uint256 public constant PLATFORM_FEE_BPS = 10;

    // ============ Dispute Constants (Story 3.4) ============

    /// @notice Minimum stake required to raise a dispute (10 tokens)
    /// @dev Set dynamically based on collateral token decimals
    uint256 public immutable MIN_DISPUTE_STAKE;

    /// @notice Amount slashed from keeper for incorrect scores (0.01 tokens)
    /// @dev Set dynamically based on collateral token decimals
    uint256 public immutable KEEPER_SLASH_AMOUNT;

    /// @notice Dispute reward in basis points (5% of total pot)
    uint256 public constant DISPUTE_REWARD_BPS = 500;

    /// @notice Window after consensus during which disputes can be raised (2 hours)
    uint256 public constant DISPUTE_WINDOW = 2 hours;

    /// @notice Consensus threshold in basis points (66.67% = 6667 BPS)
    /// @dev With 3 keepers: need 2 votes (67%). With 2 keepers: need 2 votes (100%)
    uint256 public constant CONSENSUS_THRESHOLD_BPS = 6667;

    /// @notice Duration of settlement pause during active dispute (48 hours)
    uint256 public constant DISPUTE_PAUSE_DURATION = 48 hours;

    /// @notice Keeper score error threshold for slashing in basis points (5%)
    /// @dev Keeper is slashed if their score differs from corrected score by more than 5%
    uint256 public constant KEEPER_ERROR_THRESHOLD_BPS = 500;

    /// @notice Maximum length for dispute reason string (500 bytes)
    uint256 public constant MAX_DISPUTE_REASON_LENGTH = 500;

    /// @notice Maximum batch size for batch operations (gas limit protection)
    uint256 public constant MAX_BATCH_SIZE = 50;

    // ============ Structs ============

    /// @notice Keeper proposal structure for adding/removing keepers
    struct KeeperProposal {
        address proposer;
        address keeper;
        bool isRemoval;
        uint256 votesFor;
        uint256 votesAgainst;
        bool executed;
        uint256 createdAt;
    }

    /// @notice Score vote structure for portfolio bet resolution
    struct ScoreVote {
        address keeper;
        int256 score;
        bool creatorWins;
        uint256 votedAt;
    }

    /// @notice Dispute info structure for tracking disputes on bets (Story 3.4)
    struct DisputeInfo {
        address disputer;
        uint256 stake;
        string reason;
        uint256 raisedAt;
        uint256 resolvedAt;
        bool outcomeChanged;
        bool originalCreatorWins;
    }

    // ============ State Variables ============

    /// @notice Reference to AgiArenaCore address (for future settlement integration)
    address public immutable AGIARENA_CORE;

    // Keeper Registry
    /// @notice Mapping of keeper address to active status
    mapping(address => bool) public isKeeper;

    /// @notice Mapping of keeper address to registered IP:port
    mapping(address => string) public keeperIPs;

    /// @notice Array of keeper addresses for enumeration
    address[] public keepers;

    // Proposal System
    /// @notice Counter for generating unique proposal IDs
    uint256 public nextProposalId;

    /// @notice Mapping of proposal ID to KeeperProposal
    mapping(uint256 => KeeperProposal) public proposals;

    /// @notice Mapping of proposal ID => keeper => hasVoted
    mapping(uint256 => mapping(address => bool)) public hasVotedOnProposal;

    // Score Voting
    /// @notice Mapping of bet ID to array of score votes
    mapping(uint256 => ScoreVote[]) internal _betScoreVotes;

    /// @notice Mapping of bet ID => keeper => hasVoted
    mapping(uint256 => mapping(address => bool)) public hasVotedOnBet;

    /// @notice Mapping of bet ID to consensus reached status
    mapping(uint256 => bool) public consensusReached;

    // Settlement State (Story 3.3)
    /// @notice Mapping of bet ID to settled status
    mapping(uint256 => bool) public betSettled;

    /// @notice Mapping of bet ID to winner address
    mapping(uint256 => address) public betWinner;

    /// @notice Mapping of bet ID to winner payout amount
    mapping(uint256 => uint256) public winnerPayouts;

    /// @notice Mapping of bet ID to loser address (for tie scenarios where both get paid)
    mapping(uint256 => address) public betLoser;

    /// @notice Mapping of bet ID to loser payout amount (for tie scenarios)
    mapping(uint256 => uint256) public loserPayouts;

    /// @notice Mapping of bet ID to winnings claimed status
    mapping(uint256 => bool) public winningsClaimed;

    /// @notice Mapping of bet ID to loser claimed status (for tie scenarios)
    mapping(uint256 => bool) public loserClaimed;

    /// @notice Indicates if a bet was a tie (both parties get refunds)
    mapping(uint256 => bool) public isTieBet;

    /// @notice Accumulated platform fees available for withdrawal
    uint256 public accumulatedFees;

    // Dispute State (Story 3.4)
    /// @notice Mapping of bet ID to dispute info
    mapping(uint256 => DisputeInfo) public disputes;

    /// @notice Mapping of bet ID to disputed status (quick lookup)
    mapping(uint256 => bool) public isDisputed;

    /// @notice Mapping of bet ID to corrected scores after dispute resolution
    mapping(uint256 => int256) public correctedScores;

    /// @notice Mapping of bet ID => keeper => slashed status (prevent double slash)
    mapping(uint256 => mapping(address => bool)) public keeperSlashed;

    /// @notice Mapping of bet ID to timestamp when consensus was reached
    mapping(uint256 => uint256) public consensusTimestamp;

    // ============ Events ============

    /// @notice Emitted when a keeper is proposed for addition or removal
    /// @param proposalId The unique proposal identifier
    /// @param proposer The address that created the proposal
    /// @param keeper The keeper address being proposed
    /// @param isRemoval True if this is a removal proposal
    event KeeperProposed(uint256 indexed proposalId, address indexed proposer, address keeper, bool isRemoval);

    /// @notice Emitted when a keeper is added via governance
    /// @param keeper The keeper address that was added
    /// @param proposalId The proposal ID that added this keeper
    event KeeperAdded(address indexed keeper, uint256 proposalId);

    /// @notice Emitted when a keeper is removed via governance
    /// @param keeper The keeper address that was removed
    /// @param proposalId The proposal ID that removed this keeper
    event KeeperRemoved(address indexed keeper, uint256 proposalId);

    /// @notice Emitted when a keeper registers or updates their IP
    /// @param keeper The keeper address
    /// @param ipAddress The registered IP:port string
    event KeeperIPRegistered(address indexed keeper, string ipAddress);

    /// @notice Emitted when a keeper casts a vote on a bet's portfolio score
    /// @param betId The bet ID being voted on
    /// @param keeper The keeper who voted
    /// @param score The aggregate portfolio score in basis points
    /// @param creatorWins True if keeper determines creator wins
    /// @dev DEPRECATED: Use PortfolioScoreVoted instead. Kept for backward compatibility with existing indexers.
    ///      Will be removed in a future version. Migrate indexers to PortfolioScoreVoted by Q2 2026.
    event VoteCast(uint256 indexed betId, address indexed keeper, int256 score, bool creatorWins);

    /// @notice Emitted when consensus is reached on a bet's outcome
    /// @param betId The bet ID
    /// @param creatorWins True if creator wins
    /// @param score1 First keeper's score
    /// @param score2 Second keeper's score
    /// @dev DEPRECATED: Use ScoreConsensusReached instead. Kept for backward compatibility with existing indexers.
    ///      Will be removed in a future version. Migrate indexers to ScoreConsensusReached by Q2 2026.
    event ConsensusReached(uint256 indexed betId, bool creatorWins, int256 score1, int256 score2);

    /// @notice Emitted when a keeper votes on a proposal
    /// @param proposalId The proposal ID
    /// @param keeper The keeper who voted
    /// @param approve True if vote is in favor
    event ProposalVoteCast(uint256 indexed proposalId, address indexed keeper, bool approve);

    /// @notice Emitted when a keeper votes on a portfolio score (Story 3.2)
    /// @param betId The bet ID being voted on
    /// @param keeper The keeper who voted
    /// @param score The aggregate portfolio score in basis points
    /// @param creatorWins True if keeper determines creator wins
    event PortfolioScoreVoted(uint256 indexed betId, address indexed keeper, int256 score, bool creatorWins);

    /// @notice Emitted when score consensus is reached (Story 3.2)
    /// @param betId The bet ID
    /// @param avgScore Average of keeper scores
    /// @param creatorWins True if creator wins
    event ScoreConsensusReached(uint256 indexed betId, int256 avgScore, bool creatorWins);

    /// @notice Emitted when keepers have divergent outcomes (Story 3.2)
    /// @param betId The bet ID
    /// @param score1 First keeper's score
    /// @param score2 Second keeper's score
    /// @param diff Absolute difference between scores
    event ScoreDivergence(uint256 indexed betId, int256 score1, int256 score2, uint256 diff);

    // Settlement Events (Story 3.3)
    /// @notice Emitted when a bet is settled
    /// @param betId The bet ID that was settled
    /// @param winner The winner address
    /// @param loser The loser address
    /// @param totalPot Total amount in the pot (creator amount + matched amount)
    /// @param platformFee The platform fee deducted
    /// @param winnerPayout The amount awarded to winner
    event BetSettled(
        uint256 indexed betId,
        address indexed winner,
        address loser,
        uint256 totalPot,
        uint256 platformFee,
        uint256 winnerPayout
    );

    /// @notice Emitted when winnings are claimed
    /// @param betId The bet ID
    /// @param winner The winner who claimed
    /// @param amount The amount claimed
    event WinningsClaimed(uint256 indexed betId, address indexed winner, uint256 amount);

    /// @notice Emitted when platform fees are withdrawn
    /// @param recipient The fee recipient address
    /// @param amount The amount withdrawn
    event PlatformFeesWithdrawn(address indexed recipient, uint256 amount);

    // Dispute Events (Story 3.4)
    /// @notice Emitted when a dispute is raised on a bet
    /// @param betId The bet ID being disputed
    /// @param disputer The address that raised the dispute
    /// @param stake The USDC stake amount
    /// @param reason The reason for the dispute
    event DisputeRaised(uint256 indexed betId, address indexed disputer, uint256 stake, string reason);

    /// @notice Emitted when a dispute is resolved
    /// @param betId The bet ID
    /// @param outcomeChanged Whether the outcome changed from original
    /// @param correctedScore The corrected score after recalculation
    event DisputeResolved(uint256 indexed betId, bool outcomeChanged, int256 correctedScore);

    /// @notice Emitted when a disputer's stake is slashed (fake dispute)
    /// @param disputer The disputer address
    /// @param amount The slashed amount
    event DisputerSlashed(address indexed disputer, uint256 amount);

    /// @notice Emitted when a disputer receives reward (valid dispute)
    /// @param disputer The disputer address
    /// @param amount The reward amount (stake + bonus)
    event DisputerRewarded(address indexed disputer, uint256 amount);

    /// @notice Emitted when a keeper is slashed for wrong calculation
    /// @param keeper The keeper address
    /// @param amount The slash amount
    /// @param betId The bet ID
    /// @param reason The reason for slashing
    event KeeperSlashed(address indexed keeper, uint256 amount, uint256 indexed betId, string reason);

    // ============ Modifiers ============

    /// @notice Restricts function access to whitelisted keepers only
    modifier onlyKeeper() {
        _checkKeeper();
        _;
    }

    /// @dev Internal function for onlyKeeper modifier (reduces bytecode size)
    function _checkKeeper() internal view {
        if (!isKeeper[msg.sender]) revert UnauthorizedKeeper(msg.sender);
    }

    // ============ Constructor ============

    /// @notice Initialize the ResolutionDAO with the first keeper (deployer as bootstrap)
    /// @param initialKeeper The first keeper address (typically the deployer)
    /// @param agiArenaCore The AgiArenaCore contract address (for future settlement integration)
    constructor(address initialKeeper, address agiArenaCore) {
        if (initialKeeper == address(0)) revert ZeroAddress();
        // agiArenaCore can be zero address if not yet deployed
        AGIARENA_CORE = agiArenaCore;

        // Initialize first keeper
        isKeeper[initialKeeper] = true;
        keepers.push(initialKeeper);

        // Set dispute stake and slash amount based on collateral token decimals
        uint8 decimals = agiArenaCore != address(0)
            ? IERC20Metadata(address(IAgiArenaCore(agiArenaCore).COLLATERAL_TOKEN())).decimals()
            : 6; // Default to 6 decimals (USDC)

        // 10 tokens for dispute stake
        MIN_DISPUTE_STAKE = 10 * (10 ** decimals);
        // 0.01 tokens for keeper slash
        KEEPER_SLASH_AMOUNT = 10 ** (decimals - 2);

        // Emit event for indexing (proposalId 0 = bootstrap)
        emit KeeperAdded(initialKeeper, 0);
    }

    // ============ Keeper IP Registry Functions ============

    /// @notice Register or update keeper's IP:port for off-chain discovery
    /// @param ipAddress The IP:port string (e.g., "192.168.1.1:8080")
    function registerKeeperIP(string memory ipAddress) external nonReentrant onlyKeeper {
        if (bytes(ipAddress).length == 0) revert EmptyIPAddress();

        keeperIPs[msg.sender] = ipAddress;

        emit KeeperIPRegistered(msg.sender, ipAddress);
    }

    // ============ Keeper Governance Functions ============

    /// @notice Propose a new keeper to be added
    /// @param keeper The address to propose as a new keeper
    /// @return proposalId The unique identifier for this proposal
    function proposeKeeper(address keeper) external nonReentrant onlyKeeper returns (uint256 proposalId) {
        if (keeper == address(0)) revert ZeroAddress();
        if (isKeeper[keeper]) revert KeeperAlreadyExists(keeper);
        if (keeper == msg.sender) revert CannotProposeSelf();

        proposalId = nextProposalId++;

        proposals[proposalId] = KeeperProposal({
            proposer: msg.sender,
            keeper: keeper,
            isRemoval: false,
            votesFor: 0,
            votesAgainst: 0,
            executed: false,
            createdAt: block.timestamp
        });

        emit KeeperProposed(proposalId, msg.sender, keeper, false);
    }

    /// @notice Propose removal of an existing keeper
    /// @param keeper The address of the keeper to remove
    /// @return proposalId The unique identifier for this proposal
    function proposeKeeperRemoval(address keeper) external nonReentrant onlyKeeper returns (uint256 proposalId) {
        if (!isKeeper[keeper]) revert KeeperNotFound(keeper);
        // Cannot remove if only one keeper left (would break governance)
        if (keepers.length <= 1) revert CannotRemoveLastKeeper();

        proposalId = nextProposalId++;

        proposals[proposalId] = KeeperProposal({
            proposer: msg.sender,
            keeper: keeper,
            isRemoval: true,
            votesFor: 0,
            votesAgainst: 0,
            executed: false,
            createdAt: block.timestamp
        });

        emit KeeperProposed(proposalId, msg.sender, keeper, true);
    }

    /// @notice Vote on a keeper proposal
    /// @param proposalId The proposal ID to vote on
    /// @param approve True to vote in favor, false to vote against
    function voteOnKeeperProposal(uint256 proposalId, bool approve) external nonReentrant onlyKeeper {
        KeeperProposal storage proposal = proposals[proposalId];

        // Validate proposal exists
        if (proposal.createdAt == 0) revert ProposalNotFound(proposalId);

        // Check if already executed
        if (proposal.executed) revert ProposalAlreadyExecuted(proposalId);

        // Check if expired
        if (block.timestamp > proposal.createdAt + PROPOSAL_EXPIRY) {
            revert ProposalExpired(proposalId);
        }

        // Check if already voted
        if (hasVotedOnProposal[proposalId][msg.sender]) {
            revert AlreadyVotedOnProposal(msg.sender, proposalId);
        }

        // Record vote
        hasVotedOnProposal[proposalId][msg.sender] = true;

        if (approve) {
            proposal.votesFor++;
        } else {
            proposal.votesAgainst++;
        }

        emit ProposalVoteCast(proposalId, msg.sender, approve);
    }

    /// @notice Execute a keeper proposal if majority approves
    /// @param proposalId The proposal ID to execute
    function executeKeeperProposal(uint256 proposalId) external nonReentrant onlyKeeper {
        KeeperProposal storage proposal = proposals[proposalId];

        // Validate proposal exists
        if (proposal.createdAt == 0) revert ProposalNotFound(proposalId);

        // Check if already executed
        if (proposal.executed) revert ProposalAlreadyExecuted(proposalId);

        // Check if expired
        if (block.timestamp > proposal.createdAt + PROPOSAL_EXPIRY) {
            revert ProposalExpired(proposalId);
        }

        // For MVP with 2 keepers: both must vote for (majority = 100%)
        // This ensures 2-of-2 consensus
        uint256 totalKeepers = keepers.length;
        uint256 requiredVotes = totalKeepers; // All keepers must vote for

        if (proposal.votesFor < requiredVotes) revert QuorumNotReached(proposalId);

        // Mark as executed before state changes
        proposal.executed = true;

        if (proposal.isRemoval) {
            // Remove keeper
            _removeKeeper(proposal.keeper);
            emit KeeperRemoved(proposal.keeper, proposalId);
        } else {
            // Add keeper
            isKeeper[proposal.keeper] = true;
            keepers.push(proposal.keeper);
            emit KeeperAdded(proposal.keeper, proposalId);
        }
    }

    // ============ Portfolio Score Voting Functions ============

    /// @notice Submit aggregate portfolio score vote for a bet
    /// @dev Score in basis points: +247 = +2.47%, -51 = -0.51%
    /// @param betId The bet ID to vote on
    /// @param aggregateScore The aggregate portfolio score in basis points (-10000 to +10000)
    /// @param creatorWins True if keeper determines creator wins, false if matcher wins
    function voteOnPortfolioScore(
        uint256 betId,
        int256 aggregateScore,
        bool creatorWins
    ) external nonReentrant onlyKeeper {
        // Validate score range
        if (aggregateScore < MIN_SCORE || aggregateScore > MAX_SCORE) {
            revert InvalidScore(aggregateScore);
        }

        // Check if already voted
        if (hasVotedOnBet[betId][msg.sender]) {
            revert AlreadyVoted(msg.sender, betId);
        }

        // Record vote with explicit creatorWins parameter (no longer derived from score sign)
        hasVotedOnBet[betId][msg.sender] = true;
        _betScoreVotes[betId].push(
            ScoreVote({ keeper: msg.sender, score: aggregateScore, creatorWins: creatorWins, votedAt: block.timestamp })
        );

        // Emit new event (Story 3.2) for detailed score tracking
        emit PortfolioScoreVoted(betId, msg.sender, aggregateScore, creatorWins);

        // DEPRECATED: Keep legacy event for backward compatibility - remove after Q2 2026
        emit VoteCast(betId, msg.sender, aggregateScore, creatorWins);

        // Check for consensus (both keepers voted same creatorWins)
        _checkConsensus(betId);
    }

    /// @notice Batch vote on multiple portfolio scores in one transaction (gas efficient)
    /// @dev Only callable by authorized keeper
    /// @dev Skips bets where keeper has already voted (no revert)
    /// @param betIds Array of bet IDs to vote on
    /// @param aggregateScores Array of aggregate scores in basis points
    /// @param creatorWinsFlags Array of outcome flags (true = creator wins)
    function voteOnPortfolioScores(
        uint256[] calldata betIds,
        int256[] calldata aggregateScores,
        bool[] calldata creatorWinsFlags
    ) external nonReentrant onlyKeeper {
        // Validate array lengths match
        require(betIds.length == aggregateScores.length && betIds.length == creatorWinsFlags.length, "Array length mismatch");
        require(betIds.length <= MAX_BATCH_SIZE, "Batch too large");

        for (uint256 i = 0; i < betIds.length; i++) {
            // Skip if already voted (don't revert)
            if (hasVotedOnBet[betIds[i]][msg.sender]) {
                continue;
            }

            // Validate score range
            if (aggregateScores[i] < MIN_SCORE || aggregateScores[i] > MAX_SCORE) {
                continue; // Skip invalid scores in batch mode
            }

            // Record vote
            hasVotedOnBet[betIds[i]][msg.sender] = true;
            _betScoreVotes[betIds[i]].push(
                ScoreVote({
                    keeper: msg.sender,
                    score: aggregateScores[i],
                    creatorWins: creatorWinsFlags[i],
                    votedAt: block.timestamp
                })
            );

            // Emit events
            emit PortfolioScoreVoted(betIds[i], msg.sender, aggregateScores[i], creatorWinsFlags[i]);
            emit VoteCast(betIds[i], msg.sender, aggregateScores[i], creatorWinsFlags[i]);

            // Check for consensus
            _checkConsensus(betIds[i]);
        }
    }

    /// @notice Get vote status for a bet
    /// @param betId The bet ID to query
    /// @return voteCount Number of votes cast
    /// @return hasConsensus Whether consensus has been reached
    /// @return creatorWinsVotes Number of votes for creator wins
    /// @return matcherWinsVotes Number of votes for matcher wins
    function getVoteStatus(uint256 betId)
        external
        view
        returns (uint256 voteCount, bool hasConsensus, uint256 creatorWinsVotes, uint256 matcherWinsVotes)
    {
        ScoreVote[] storage votes = _betScoreVotes[betId];
        voteCount = votes.length;
        hasConsensus = consensusReached[betId];

        for (uint256 i = 0; i < votes.length; i++) {
            if (votes[i].creatorWins) {
                creatorWinsVotes++;
            } else {
                matcherWinsVotes++;
            }
        }
    }

    // ============ View Functions ============

    /// @notice Get the number of active keepers
    /// @return The number of keepers
    function getKeeperCount() external view returns (uint256) {
        return keepers.length;
    }

    /// @notice Get keeper address at index
    /// @param index The index in the keepers array
    /// @return The keeper address at that index
    function getKeeperAtIndex(uint256 index) external view returns (address) {
        return keepers[index];
    }

    /// @notice Get keeper's registered IP address
    /// @param keeper The keeper address
    /// @return The registered IP:port string
    function getKeeperIP(address keeper) external view returns (string memory) {
        return keeperIPs[keeper];
    }

    /// @notice Get proposal details
    /// @param proposalId The proposal ID
    /// @return The KeeperProposal struct
    function getProposal(uint256 proposalId) external view returns (KeeperProposal memory) {
        return proposals[proposalId];
    }

    /// @notice Get all votes for a bet
    /// @param betId The bet ID
    /// @return Array of ScoreVote structs
    function getBetVotes(uint256 betId) external view returns (ScoreVote[] memory) {
        return _betScoreVotes[betId];
    }

    /// @notice Get all score votes for a bet (alias for getBetVotes per Story 3.2 AC)
    /// @param betId The bet ID
    /// @return Array of ScoreVote structs containing (keeper, score, creatorWins, votedAt)
    function getScoreVotes(uint256 betId) external view returns (ScoreVote[] memory) {
        return _betScoreVotes[betId];
    }

    /// @notice Check if keeper scores are within tolerance and have consensus
    /// @param betId The bet ID to check
    /// @param toleranceBps Tolerance in basis points (e.g., 10 = 0.1%)
    /// @return hasConsensus Whether sufficient keepers voted same outcome (67% threshold)
    /// @return withinTolerance Whether score difference is within tolerance
    /// @return avgScore Average of all keeper scores (0 if no votes)
    /// @return scoreDiff Max score difference between any two votes (0 if less than 2 votes)
    function checkScoreConsensus(
        uint256 betId,
        uint256 toleranceBps
    ) external view returns (bool hasConsensus, bool withinTolerance, int256 avgScore, uint256 scoreDiff) {
        ScoreVote[] storage votes = _betScoreVotes[betId];
        uint256 totalKeepers = keepers.length;

        // Edge case: no votes
        if (votes.length == 0) {
            return (false, false, 0, 0);
        }

        // Edge case: single vote or insufficient keepers
        if (votes.length == 1 || totalKeepers < 2) {
            return (false, false, votes[0].score, 0);
        }

        // Calculate required votes for consensus (67% of total keepers, minimum 2)
        uint256 requiredVotes = (totalKeepers * CONSENSUS_THRESHOLD_BPS) / 10000;
        if (requiredVotes < 2) requiredVotes = 2;

        // Count votes for each outcome and calculate stats
        uint256 creatorWinsVotes = 0;
        uint256 matcherWinsVotes = 0;
        int256 totalScore = 0;
        int256 minScore = votes[0].score;
        int256 maxScore = votes[0].score;

        for (uint256 i = 0; i < votes.length; i++) {
            if (votes[i].creatorWins) {
                creatorWinsVotes++;
            } else {
                matcherWinsVotes++;
            }
            totalScore += votes[i].score;
            if (votes[i].score < minScore) minScore = votes[i].score;
            if (votes[i].score > maxScore) maxScore = votes[i].score;
        }

        // Check if either outcome has reached consensus threshold
        hasConsensus = creatorWinsVotes >= requiredVotes || matcherWinsVotes >= requiredVotes;

        // Calculate average score
        avgScore = totalScore / int256(votes.length);

        // Calculate max score difference
        int256 diff = maxScore - minScore;
        scoreDiff = diff >= 0 ? uint256(diff) : uint256(-diff);

        // Check if within tolerance
        withinTolerance = scoreDiff <= toleranceBps;
    }

    // ============ Settlement Functions (Story 3.3) ============

    /// @notice Settle a bet after keeper consensus - permissionless, anyone can call
    /// @dev Caller pays gas but receives no reward. Settlement trusts keeper votes.
    ///      If bet was disputed, uses corrected score if outcome changed.
    /// @param betId The bet ID to settle
    function settleBet(uint256 betId) external nonReentrant {
        _settleBetInternal(betId);
    }

    /// @notice Batch settle multiple bets in one transaction (gas efficient)
    /// @dev Permissionless - anyone can call. Skips bets that can't be settled.
    /// @param betIds Array of bet IDs to settle
    function settleBets(uint256[] calldata betIds) external nonReentrant {
        require(betIds.length <= MAX_BATCH_SIZE, "Batch too large");

        for (uint256 i = 0; i < betIds.length; i++) {
            _settleBetInternalSafe(betIds[i]);
        }
    }

    /// @dev Internal settlement logic
    function _settleBetInternal(uint256 betId) internal {
        // Check consensus reached
        if (!consensusReached[betId]) revert ConsensusNotReached(betId);

        // Check not already settled
        if (betSettled[betId]) revert BetAlreadySettled(betId);

        // Story 3.4: Check dispute state
        if (isDisputed[betId]) {
            // If disputed but not resolved, cannot settle
            if (disputes[betId].resolvedAt == 0) revert DisputePending(betId);
            // If resolved, proceed - _executeSettlement will check if outcome changed
        }

        // Execute settlement in helper to avoid stack too deep
        _executeSettlement(betId);
    }

    /// @dev Safe version that doesn't revert on failure (for batch operations)
    function _settleBetInternalSafe(uint256 betId) internal {
        // Skip if no consensus
        if (!consensusReached[betId]) return;

        // Skip if already settled
        if (betSettled[betId]) return;

        // Skip if disputed but not resolved
        if (isDisputed[betId] && disputes[betId].resolvedAt == 0) return;

        // Try to execute settlement (may fail for other reasons)
        _executeSettlement(betId);
    }

    /// @dev Internal helper to execute settlement logic
    /// @notice Determines winner from keeper votes, calculates payouts, and records settlement state
    ///         If bet was disputed and outcome changed, uses the corrected outcome.
    /// @param betId The bet ID to settle
    function _executeSettlement(uint256 betId) internal {
        // Get keeper vote outcome (both keepers agree due to consensus)
        ScoreVote[] storage votes = _betScoreVotes[betId];
        bool creatorWins = votes[0].creatorWins;

        // Story 3.4: If disputed and outcome changed, flip the winner
        if (isDisputed[betId] && disputes[betId].outcomeChanged) {
            creatorWins = !disputes[betId].originalCreatorWins;
        }

        // Get bet data from AgiArenaCore
        (uint256 creatorStake, uint256 matchedAmount, address creator, address filler) = _getBetParties(betId);

        // Calculate total pot and platform fee
        uint256 totalPot = creatorStake + matchedAmount;
        uint256 platformFee = (totalPot * PLATFORM_FEE_BPS) / 10000;

        // Check for tie (both scores exactly 0)
        // If disputed, use corrected score for tie check
        int256 effectiveScore1;
        int256 effectiveScore2;
        if (isDisputed[betId] && disputes[betId].resolvedAt > 0) {
            // Use corrected score - treat as if both keepers voted the corrected score
            effectiveScore1 = correctedScores[betId];
            effectiveScore2 = correctedScores[betId];
        } else {
            effectiveScore1 = votes[0].score;
            effectiveScore2 = votes[1].score;
        }
        bool isTie = (effectiveScore1 == 0 && effectiveScore2 == 0);

        if (isTie) {
            _handleTieSettlement(betId, creatorStake, matchedAmount, platformFee, totalPot, creator, filler);
        } else {
            _handleWinnerSettlement(betId, creatorWins, platformFee, totalPot, creator, filler);
        }
    }

    /// @dev Get bet parties from AgiArenaCore
    /// @notice Retrieves bet data and validates it's in a settleable state
    /// @param betId The bet ID to get parties for
    /// @return creatorStake The creator's original bet amount
    /// @return matchedAmount The total matched amount from fillers
    /// @return creator The bet creator address
    /// @return filler The first filler address (MVP: single filler support)
    function _getBetParties(uint256 betId)
        internal
        view
        returns (uint256 creatorStake, uint256 matchedAmount, address creator, address filler)
    {
        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        IAgiArenaCore.BetStatus status;
        (
            , // betHash - not needed for settlement
            , // jsonStorageRef - not needed for settlement
            creatorStake,
            , // requiredMatch - not needed for settlement, matchedAmount is the actual amount
            matchedAmount,
            , // oddsBps - not needed for settlement (payout is creatorStake + matchedAmount)
            creator,
            status,
        ) = core.bets(betId);

        // Validate bet is in correct status (FullyMatched or PartiallyMatched)
        if (status != IAgiArenaCore.BetStatus.FullyMatched && status != IAgiArenaCore.BetStatus.PartiallyMatched) {
            revert InvalidBetStatus(betId);
        }

        // Get filler address (first filler for MVP)
        IAgiArenaCore.Fill[] memory fills = core.getBetFills(betId);
        if (fills.length == 0) {
            revert NoFiller(betId);
        }
        filler = fills[0].filler;
    }

    /// @dev Handle tie settlement (both scores exactly 0)
    /// @notice In tie scenarios, both creator and filler get their original amounts back minus half the fee each
    /// @param betId The bet ID being settled
    /// @param amount The creator's original bet amount
    /// @param matchedAmount The filler's matched amount
    /// @param platformFee The total platform fee to deduct
    /// @param totalPot The total pot (amount + matchedAmount)
    /// @param creator The bet creator address
    /// @param filler The bet filler address
    function _handleTieSettlement(
        uint256 betId,
        uint256 amount,
        uint256 matchedAmount,
        uint256 platformFee,
        uint256 totalPot,
        address creator,
        address filler
    ) internal {
        // Tie case: both parties get their original amounts back minus proportional fee
        // Fee split proportionally based on contribution to pot
        uint256 creatorFeeShare = (platformFee * amount) / totalPot;
        uint256 fillerFeeShare = platformFee - creatorFeeShare; // Handles rounding

        uint256 creatorReturn = amount - creatorFeeShare;
        uint256 fillerReturn = matchedAmount - fillerFeeShare;

        // Store both payouts for tie (CEI pattern: effects before interactions)
        betSettled[betId] = true;
        isTieBet[betId] = true;
        betWinner[betId] = creator;
        winnerPayouts[betId] = creatorReturn;
        betLoser[betId] = filler;
        loserPayouts[betId] = fillerReturn;
        accumulatedFees += platformFee;

        // Emit event (creator listed as "winner" for consistency, but both get paid in tie)
        emit BetSettled(betId, creator, filler, totalPot, platformFee, creatorReturn);
    }

    /// @dev Handle normal winner settlement (non-tie case)
    /// @notice Records winner/loser and calculates payout after platform fee deduction
    /// @param betId The bet ID being settled
    /// @param creatorWins True if creator wins, false if filler wins
    /// @param platformFee The platform fee to deduct from total pot
    /// @param totalPot The total pot (creator amount + matched amount)
    /// @param creator The bet creator address
    /// @param filler The bet filler address
    function _handleWinnerSettlement(
        uint256 betId,
        bool creatorWins,
        uint256 platformFee,
        uint256 totalPot,
        address creator,
        address filler
    ) internal {
        uint256 winnerPayout = totalPot - platformFee;
        address winner = creatorWins ? creator : filler;
        address loser = creatorWins ? filler : creator;

        // Record settlement state (CEI pattern: effects before interactions)
        betSettled[betId] = true;
        betWinner[betId] = winner;
        winnerPayouts[betId] = winnerPayout;
        accumulatedFees += platformFee;

        emit BetSettled(betId, winner, loser, totalPot, platformFee, winnerPayout);
    }

    /// @notice Claim winnings for a settled bet (winner) or refund (tie participant)
    /// @dev Winner or tie participant can claim. Uses SafeERC20 for transfer.
    /// @param betId The bet ID to claim winnings for
    function claimWinnings(uint256 betId) external nonReentrant {
        // Verify bet is settled
        if (!betSettled[betId]) revert InvalidBetStatus(betId);

        uint256 payout;
        bool isWinner = betWinner[betId] == msg.sender;
        bool isLoserInTie = isTieBet[betId] && betLoser[betId] == msg.sender;

        if (isWinner) {
            // Verify winnings not already claimed
            if (winningsClaimed[betId]) revert NoWinningsAvailable(betId);

            payout = winnerPayouts[betId];
            if (payout == 0) revert NoWinningsAvailable(betId);

            // Mark as claimed (CEI pattern: effects before interactions)
            winningsClaimed[betId] = true;
        } else if (isLoserInTie) {
            // Tie scenario: loser also gets their refund
            if (loserClaimed[betId]) revert NoWinningsAvailable(betId);

            payout = loserPayouts[betId];
            if (payout == 0) revert NoWinningsAvailable(betId);

            // Mark as claimed (CEI pattern: effects before interactions)
            loserClaimed[betId] = true;
        } else {
            revert NotWinner(msg.sender, betId);
        }

        // Get USDC from AgiArenaCore and transfer to claimant
        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        IERC20 usdc = core.COLLATERAL_TOKEN();

        // Transfer from AgiArenaCore's balance to claimant
        // NOTE: This requires AgiArenaCore to have approved ResolutionDAO to transfer USDC
        usdc.safeTransferFrom(AGIARENA_CORE, msg.sender, payout);

        emit WinningsClaimed(betId, msg.sender, payout);
    }

    /// @notice Withdraw accumulated platform fees to the fee recipient
    /// @dev Permissionless - anyone can trigger, fees go to FEE_RECIPIENT
    function withdrawPlatformFees() external nonReentrant {
        uint256 fees = accumulatedFees;
        if (fees == 0) revert NoWinningsAvailable(0); // No fees available

        // Reset fees before transfer (CEI pattern)
        accumulatedFees = 0;

        // Get fee recipient and USDC from AgiArenaCore
        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        address feeRecipient = core.FEE_RECIPIENT();
        IERC20 usdc = core.COLLATERAL_TOKEN();

        // Transfer fees from AgiArenaCore to fee recipient
        usdc.safeTransferFrom(AGIARENA_CORE, feeRecipient, fees);

        emit PlatformFeesWithdrawn(feeRecipient, fees);
    }

    // ============ Settlement View Functions (Story 3.3) ============

    /// @notice Get settlement status for a bet
    /// @param betId The bet ID to query
    /// @return isSettled Whether the bet has been settled
    /// @return winner The winner address (zero if not settled)
    /// @return payout The winner payout amount
    /// @return claimed Whether winnings have been claimed
    function getBetSettlementStatus(uint256 betId)
        external
        view
        returns (bool isSettled, address winner, uint256 payout, bool claimed)
    {
        isSettled = betSettled[betId];
        winner = betWinner[betId];
        payout = winnerPayouts[betId];
        claimed = winningsClaimed[betId];
    }

    /// @notice Get accumulated platform fees available for withdrawal
    /// @return Total unclaimed platform fees
    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }

    /// @notice Check if a bet can be settled
    /// @param betId The bet ID to check
    /// @return True if bet has consensus, is not yet settled, dispute resolved (if any), and is in valid status
    function canSettleBet(uint256 betId) external view returns (bool) {
        if (!consensusReached[betId] || betSettled[betId]) {
            return false;
        }

        // Story 3.4: Check dispute state
        if (isDisputed[betId] && disputes[betId].resolvedAt == 0) {
            // Dispute pending - cannot settle
            return false;
        }

        // Also verify bet is in settleable status
        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        (, , , , , , , IAgiArenaCore.BetStatus status,) = core.bets(betId);

        // Only FullyMatched or PartiallyMatched bets can be settled
        return status == IAgiArenaCore.BetStatus.FullyMatched ||
               status == IAgiArenaCore.BetStatus.PartiallyMatched;
    }

    // ============ Dispute Functions (Story 3.4) ============

    /// @notice Raise a dispute on a bet within the dispute window
    /// @dev Anyone can dispute by staking USDC. Stake is returned if dispute is valid.
    /// @param betId The bet ID to dispute
    /// @param stakeAmount The USDC amount to stake (must be >= MIN_DISPUTE_STAKE)
    /// @param reason The reason for the dispute (cannot be empty)
    function raiseDispute(
        uint256 betId,
        uint256 stakeAmount,
        string calldata reason
    ) external nonReentrant {
        // Verify consensus has been reached
        if (!consensusReached[betId]) revert ConsensusNotReached(betId);

        // Verify bet is not already settled
        if (betSettled[betId]) revert BetAlreadySettled(betId);

        // Verify bet is not already disputed
        if (isDisputed[betId]) revert DisputeAlreadyRaised(betId);

        // Verify within 2-hour dispute window
        uint256 deadline = consensusTimestamp[betId] + DISPUTE_WINDOW;
        if (block.timestamp > deadline) {
            revert DisputeWindowExpired(betId, consensusTimestamp[betId], deadline);
        }

        // Verify stake amount
        if (stakeAmount < MIN_DISPUTE_STAKE) {
            revert InsufficientDisputeStake(stakeAmount, MIN_DISPUTE_STAKE);
        }

        // Verify reason is not empty and not too long
        if (bytes(reason).length == 0) revert DisputeReasonRequired();
        if (bytes(reason).length > MAX_DISPUTE_REASON_LENGTH) {
            revert DisputeReasonTooLong(bytes(reason).length, MAX_DISPUTE_REASON_LENGTH);
        }

        // Get original creatorWins for later comparison
        ScoreVote[] storage votes = _betScoreVotes[betId];
        bool originalCreatorWins = votes[0].creatorWins;

        // Transfer stake from disputer to this contract (CEI: effects before interactions, but transfer needed first)
        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        IERC20 usdc = core.COLLATERAL_TOKEN();
        usdc.safeTransferFrom(msg.sender, address(this), stakeAmount);

        // Record dispute state
        isDisputed[betId] = true;
        disputes[betId] = DisputeInfo({
            disputer: msg.sender,
            stake: stakeAmount,
            reason: reason,
            raisedAt: block.timestamp,
            resolvedAt: 0,
            outcomeChanged: false,
            originalCreatorWins: originalCreatorWins
        });

        emit DisputeRaised(betId, msg.sender, stakeAmount, reason);
    }

    /// @notice Resolve a dispute with recalculated score
    /// @dev Only keepers can call. Sets the corrected score and whether outcome changed.
    /// @param betId The bet ID to resolve
    /// @param correctedScore The corrected portfolio score after recalculation
    /// @param creatorWins The corrected winner determination
    function resolveDisputeWithRecalculation(
        uint256 betId,
        int256 correctedScore,
        bool creatorWins
    ) external nonReentrant onlyKeeper {
        // Verify bet is disputed
        if (!isDisputed[betId]) revert BetNotDisputed(betId);

        // Verify dispute is not already resolved
        if (disputes[betId].resolvedAt > 0) revert DisputeAlreadyResolved(betId);

        // Validate corrected score is within valid range
        if (correctedScore < MIN_SCORE || correctedScore > MAX_SCORE) {
            revert InvalidScore(correctedScore);
        }

        // Store corrected score
        correctedScores[betId] = correctedScore;

        // Determine if outcome changed
        bool outcomeChanged = (creatorWins != disputes[betId].originalCreatorWins);

        // Update dispute info
        disputes[betId].outcomeChanged = outcomeChanged;
        disputes[betId].resolvedAt = block.timestamp;

        emit DisputeResolved(betId, outcomeChanged, correctedScore);
    }

    /// @notice Slash a disputer's stake when dispute is proven invalid
    /// @dev Only keepers can call. Stake goes to platform fees.
    /// @param betId The bet ID with the resolved dispute
    function slashDisputer(uint256 betId) external nonReentrant onlyKeeper {
        // Verify bet is disputed
        if (!isDisputed[betId]) revert BetNotDisputed(betId);

        DisputeInfo storage dispute = disputes[betId];

        // Verify dispute is resolved
        if (dispute.resolvedAt == 0) revert DisputePending(betId);

        // Verify outcome did NOT change (fake dispute)
        if (dispute.outcomeChanged) revert DisputeOutcomeChanged(betId);

        // Verify stake hasn't already been processed
        if (dispute.stake == 0) revert DisputeStakeAlreadyProcessed(betId);

        // Get stake amount before clearing
        uint256 stakeAmount = dispute.stake;

        // Clear stake to prevent double-slash (CEI pattern)
        dispute.stake = 0;

        // Add stake to accumulated fees (no transfer needed, contract already holds it)
        accumulatedFees += stakeAmount;

        emit DisputerSlashed(dispute.disputer, stakeAmount);
    }

    /// @notice Refund disputer stake plus reward when dispute is proven valid
    /// @dev Permissionless - anyone can trigger once conditions are met.
    ///      IMPORTANT: AgiArenaCore must have approved this contract to transfer USDC for the reward.
    ///      The stake is held by this contract, but the reward comes from AgiArenaCore's balance.
    /// @param betId The bet ID with the resolved dispute
    function refundDisputer(uint256 betId) external nonReentrant {
        // Verify bet is disputed
        if (!isDisputed[betId]) revert BetNotDisputed(betId);

        DisputeInfo storage dispute = disputes[betId];

        // Verify dispute is resolved
        if (dispute.resolvedAt == 0) revert DisputePending(betId);

        // Verify outcome DID change (valid dispute)
        if (!dispute.outcomeChanged) revert DisputeOutcomeUnchanged(betId);

        // Verify stake hasn't already been processed
        if (dispute.stake == 0) revert DisputeStakeAlreadyProcessed(betId);

        // Get stake amount before clearing
        uint256 stakeAmount = dispute.stake;

        // Calculate reward: 5% of total pot
        (uint256 creatorStake, uint256 matchedAmount, , ) = _getBetParties(betId);
        uint256 totalPot = creatorStake + matchedAmount;
        uint256 reward = (totalPot * DISPUTE_REWARD_BPS) / 10000;

        // Clear stake to prevent double-refund (CEI pattern)
        dispute.stake = 0;

        // Total payout = stake + reward
        uint256 totalPayout = stakeAmount + reward;

        // Transfer to disputer
        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        IERC20 usdc = core.COLLATERAL_TOKEN();

        // Transfer stake back from this contract
        usdc.safeTransfer(dispute.disputer, stakeAmount);

        // Transfer reward from AgiArenaCore (needs approval)
        if (reward > 0) {
            usdc.safeTransferFrom(AGIARENA_CORE, dispute.disputer, reward);
        }

        emit DisputerRewarded(dispute.disputer, totalPayout);
    }

    /// @notice Slash a keeper for submitting incorrect scores
    /// @dev Only keepers can call. Checks if keeper's error exceeded threshold.
    /// @param keeper The keeper address to slash
    /// @param betId The bet ID where keeper submitted wrong score
    function slashKeeper(address keeper, uint256 betId) external nonReentrant onlyKeeper {
        // Verify bet is disputed
        if (!isDisputed[betId]) revert BetNotDisputed(betId);

        // Verify dispute is resolved
        if (disputes[betId].resolvedAt == 0) revert DisputePending(betId);

        // Only slash keepers if dispute was valid (outcome changed)
        // If outcome didn't change, the original scores were correct
        if (!disputes[betId].outcomeChanged) return;

        // Verify keeper hasn't already been slashed for this bet
        if (keeperSlashed[betId][keeper]) revert KeeperAlreadySlashed(keeper, betId);

        // Find keeper's original vote
        ScoreVote[] storage votes = _betScoreVotes[betId];
        int256 keeperScore;
        bool foundKeeper = false;

        for (uint256 i = 0; i < votes.length; i++) {
            if (votes[i].keeper == keeper) {
                keeperScore = votes[i].score;
                foundKeeper = true;
                break;
            }
        }

        if (!foundKeeper) revert KeeperNotFound(keeper);

        // Get corrected score
        int256 corrected = correctedScores[betId];

        // Calculate error in basis points
        // Error = |keeperScore - correctedScore|
        int256 errorDiff = keeperScore - corrected;
        uint256 absError = errorDiff >= 0 ? uint256(errorDiff) : uint256(-errorDiff);

        // Only slash if error > KEEPER_ERROR_THRESHOLD_BPS (5%)
        if (absError <= KEEPER_ERROR_THRESHOLD_BPS) {
            // Error within tolerance, no slash
            return;
        }

        // Mark as slashed
        keeperSlashed[betId][keeper] = true;

        // Note: For MVP, keeper slash amount is symbolic (1 cent)
        // In production, this would require keepers to deposit collateral
        // For now, just emit the event - actual USDC transfer would require keeper to have approved this contract

        emit KeeperSlashed(keeper, KEEPER_SLASH_AMOUNT, betId, "Score error exceeded 5% threshold");
    }

    // ============ Dispute View Functions (Story 3.4) ============

    /// @notice Get dispute info for a bet
    /// @param betId The bet ID to query
    /// @return The DisputeInfo struct
    function getDisputeInfo(uint256 betId) external view returns (DisputeInfo memory) {
        return disputes[betId];
    }

    /// @notice Check if a dispute can be raised for a bet
    /// @param betId The bet ID to check
    /// @return True if dispute can be raised (consensus reached, not settled, not disputed, within window)
    function canRaiseDispute(uint256 betId) external view returns (bool) {
        // Must have consensus
        if (!consensusReached[betId]) return false;

        // Must not be settled
        if (betSettled[betId]) return false;

        // Must not already be disputed
        if (isDisputed[betId]) return false;

        // Must be within dispute window
        uint256 deadline = consensusTimestamp[betId] + DISPUTE_WINDOW;
        if (block.timestamp > deadline) return false;

        return true;
    }

    /// @notice Get the deadline for raising a dispute on a bet
    /// @param betId The bet ID to query
    /// @return The timestamp when the dispute window closes (0 if no consensus)
    function getDisputeDeadline(uint256 betId) external view returns (uint256) {
        if (!consensusReached[betId]) return 0;
        return consensusTimestamp[betId] + DISPUTE_WINDOW;
    }

    /// @notice Check if a keeper has been slashed for a bet
    /// @param keeper The keeper address
    /// @param betId The bet ID
    /// @return True if keeper was slashed for this bet
    function isKeeperSlashedForBet(address keeper, uint256 betId) external view returns (bool) {
        return keeperSlashed[betId][keeper];
    }

    // ============ Internal Functions ============

    /// @notice Check if consensus is reached for a bet
    /// @dev Emits ScoreConsensusReached if keepers agree, ScoreDivergence if they disagree or scores differ significantly
    ///      Consensus requires CONSENSUS_THRESHOLD_BPS (~67%) of registered keepers to agree on outcome
    /// @param betId The bet ID to check
    function _checkConsensus(uint256 betId) internal {
        ScoreVote[] storage votes = _betScoreVotes[betId];

        // Need at least 2 keepers and 2 votes for consensus
        if (keepers.length < 2 || votes.length < 2) return;

        // Calculate required votes for consensus (67% of total keepers, minimum 2)
        uint256 requiredVotes = (keepers.length * CONSENSUS_THRESHOLD_BPS) / 10000;
        if (requiredVotes < 2) requiredVotes = 2;

        // Count votes and calculate totals
        (uint256 creatorWinsVotes, int256 totalScore) = _countVotes(votes);
        uint256 matcherWinsVotes = votes.length - creatorWinsVotes;

        // Check if either outcome has reached consensus threshold
        if ((creatorWinsVotes >= requiredVotes || matcherWinsVotes >= requiredVotes) && !consensusReached[betId]) {
            _emitConsensus(betId, votes, creatorWinsVotes >= requiredVotes, totalScore);
        } else if (creatorWinsVotes > 0 && matcherWinsVotes > 0) {
            // Votes are split - emit divergence event
            _emitDivergence(betId, votes[0].score, votes[1].score);
        }
    }

    /// @dev Helper to count votes and total score
    function _countVotes(ScoreVote[] storage votes) internal view returns (uint256 creatorWinsVotes, int256 totalScore) {
        for (uint256 i = 0; i < votes.length; i++) {
            if (votes[i].creatorWins) creatorWinsVotes++;
            totalScore += votes[i].score;
        }
    }

    /// @dev Helper to emit consensus events
    function _emitConsensus(uint256 betId, ScoreVote[] storage votes, bool creatorWins, int256 totalScore) internal {
        consensusReached[betId] = true;
        consensusTimestamp[betId] = block.timestamp;

        int256 avgScore = totalScore / int256(votes.length);
        emit ScoreConsensusReached(betId, avgScore, creatorWins);

        // DEPRECATED: Legacy event for backward compatibility
        emit ConsensusReached(betId, creatorWins, votes[0].score, votes.length > 1 ? votes[1].score : votes[0].score);

        // Check for score divergence
        (int256 minScore, int256 maxScore) = _getScoreRange(votes);
        if (uint256(maxScore - minScore) > DEFAULT_TOLERANCE_BPS) {
            emit ScoreDivergence(betId, minScore, maxScore, uint256(maxScore - minScore));
        }
    }

    /// @dev Helper to get min and max scores from votes
    function _getScoreRange(ScoreVote[] storage votes) internal view returns (int256 minScore, int256 maxScore) {
        minScore = votes[0].score;
        maxScore = votes[0].score;
        for (uint256 i = 1; i < votes.length; i++) {
            if (votes[i].score < minScore) minScore = votes[i].score;
            if (votes[i].score > maxScore) maxScore = votes[i].score;
        }
    }

    /// @dev Helper to emit divergence event
    function _emitDivergence(uint256 betId, int256 score1, int256 score2) internal {
        int256 diff = score1 - score2;
        uint256 scoreDiff = diff >= 0 ? uint256(diff) : uint256(-diff);
        emit ScoreDivergence(betId, score1, score2, scoreDiff);
    }

    /// @notice Remove a keeper from the registry
    /// @param keeper The keeper address to remove
    function _removeKeeper(address keeper) internal {
        isKeeper[keeper] = false;
        delete keeperIPs[keeper];

        // Remove from array
        for (uint256 i = 0; i < keepers.length; i++) {
            if (keepers[i] == keeper) {
                // Swap with last element and pop
                keepers[i] = keepers[keepers.length - 1];
                keepers.pop();
                break;
            }
        }
    }
}
