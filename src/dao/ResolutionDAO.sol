// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IAgiArenaCore
/// @notice Interface for AgiArenaCore bet data access (updated for snapshot fields)
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

    /// @notice Bet struct matching AgiArenaCore (with snapshot fields)
    struct Bet {
        bytes32 tradesHash;        // keccak256(snapshotId + positionBitmap) - computed on-chain
        string snapshotId;         // Snapshot ID string (links bet to standardized trade list)
        string jsonStorageRef;     // Off-chain reference for bitmap storage
        uint256 creatorStake;      // Creator's collateral stake
        uint256 requiredMatch;     // Required matcher stake (calculated from odds)
        uint256 matchedAmount;     // Amount filled by counter-parties
        uint32 oddsBps;            // Odds in basis points (10000 = 1.00x)
        address creator;           // Bet creator address
        BetStatus status;          // Current bet status
        uint256 createdAt;         // Block timestamp when bet was placed
        uint256 resolutionDeadline;// Unix timestamp when bet can be resolved
    }

    /// @notice Fill struct matching AgiArenaCore
    struct Fill {
        address filler;
        uint256 amount;
        uint256 filledAt;
    }

    /// @notice Get bet data by ID (with snapshot fields)
    function bets(uint256 betId) external view returns (
        bytes32 tradesHash,
        string memory snapshotId,
        string memory jsonStorageRef,
        uint256 creatorStake,
        uint256 requiredMatch,
        uint256 matchedAmount,
        uint32 oddsBps,
        address creator,
        BetStatus status,
        uint256 createdAt,
        uint256 resolutionDeadline
    );

    /// @notice Get all fills for a bet
    function getBetFills(uint256 betId) external view returns (Fill[] memory);

    /// @notice Get the collateral token address
    function COLLATERAL_TOKEN() external view returns (IERC20);

    /// @notice Get the fee recipient address
    function FEE_RECIPIENT() external view returns (address);
}

/// @title ResolutionDAO
/// @notice Keeper DAO contract with majority-wins resolution for multi-source category betting
/// @dev Implements fully decentralized governance - NO admin functions
/// @dev CLEAN BREAK from score-based voting - uses win/loss counts per trade
contract ResolutionDAO is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Custom Errors ============

    /// @notice Thrown when caller is not an authorized keeper
    error UnauthorizedKeeper(address caller);

    /// @notice Thrown when proposal does not exist
    error ProposalNotFound(uint256 proposalId);

    /// @notice Thrown when proposal has already been executed
    error ProposalAlreadyExecuted(uint256 proposalId);

    /// @notice Thrown when proposal has expired
    error ProposalExpired(uint256 proposalId);

    /// @notice Thrown when keeper already exists
    error KeeperAlreadyExists(address keeper);

    /// @notice Thrown when keeper does not exist
    error KeeperNotFound(address keeper);

    /// @notice Thrown when keeper has already voted on a proposal
    error AlreadyVotedOnProposal(address keeper, uint256 proposalId);

    /// @notice Thrown when quorum not reached for proposal execution
    error QuorumNotReached(uint256 proposalId);

    /// @notice Thrown when trying to propose self as keeper
    error CannotProposeSelf();

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /// @notice Thrown when IP address is empty
    error EmptyIPAddress();

    /// @notice Thrown when trying to remove last keeper
    error CannotRemoveLastKeeper();

    /// @notice Thrown when bet has already been resolved
    error BetAlreadyResolved(uint256 betId);

    /// @notice Thrown when bet is not resolved yet
    error BetNotResolved(uint256 betId);

    /// @notice Thrown when trying to settle a bet that has already been settled
    error BetAlreadySettled(uint256 betId);

    /// @notice Thrown when caller is not the winner trying to claim winnings
    error NotWinner(address caller, uint256 betId);

    /// @notice Thrown when no winnings are available to claim
    error NoWinningsAvailable(uint256 betId);

    /// @notice Thrown when bet status is invalid for the operation
    error InvalidBetStatus(uint256 betId);

    /// @notice Thrown when bet has no filler (cannot settle without counter-party)
    error NoFiller(uint256 betId);

    /// @notice Thrown when resolution data is invalid
    error InvalidResolutionData();

    /// @notice Thrown when tie condition doesn't match winsCount/validTrades
    error InvalidTieCondition();

    /// @notice Thrown when cancelled condition doesn't match validTrades
    error InvalidCancelledCondition();

    /// @notice Thrown when creatorWins doesn't match winsCount/validTrades
    error InvalidCreatorWinsCondition();

    // ============ Dispute Custom Errors ============

    /// @notice Thrown when dispute window has expired
    error DisputeWindowExpired(uint256 betId, uint256 resolvedAt, uint256 deadline);

    /// @notice Thrown when a dispute has already been raised for this bet
    error DisputeAlreadyRaised(uint256 betId);

    /// @notice Thrown when no dispute exists for this bet
    error DisputeNotFound(uint256 betId);

    /// @notice Thrown when dispute stake is below minimum required
    error InsufficientDisputeStake(uint256 provided, uint256 required);

    /// @notice Thrown when dispute reason is empty
    error DisputeReasonRequired();

    /// @notice Thrown when trying to settle a bet with unresolved dispute
    error DisputePending(uint256 betId);

    /// @notice Thrown when dispute is already resolved
    error DisputeAlreadyResolved(uint256 betId);

    /// @notice Thrown when bet is not disputed
    error BetNotDisputed(uint256 betId);

    /// @notice Thrown when dispute outcome did not change (for refund)
    error DisputeOutcomeUnchanged(uint256 betId);

    /// @notice Thrown when dispute outcome did change (for slash)
    error DisputeOutcomeChanged(uint256 betId);

    /// @notice Thrown when disputer stake has already been processed
    error DisputeStakeAlreadyProcessed(uint256 betId);

    /// @notice Thrown when dispute reason exceeds maximum length
    error DisputeReasonTooLong(uint256 length, uint256 maxLength);

    // ============ Constants ============

    /// @notice Proposal expiry duration (7 days)
    uint256 public constant PROPOSAL_EXPIRY = 7 days;

    /// @notice Platform fee in basis points (0.1% = 10 bps)
    uint256 public constant PLATFORM_FEE_BPS = 10;

    /// @notice Minimum stake required to raise a dispute (10 tokens)
    uint256 public immutable MIN_DISPUTE_STAKE;

    /// @notice Dispute reward in basis points (5% of total pot)
    uint256 public constant DISPUTE_REWARD_BPS = 500;

    /// @notice Window after resolution during which disputes can be raised (2 hours)
    uint256 public constant DISPUTE_WINDOW = 2 hours;

    /// @notice Maximum batch size for batch operations (gas limit protection)
    uint256 public constant MAX_BATCH_SIZE = 50;

    /// @notice Maximum length for dispute/cancel reason string (500 bytes)
    uint256 public constant MAX_REASON_LENGTH = 500;

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

    /// @notice Bet resolution structure for majority-wins resolution
    /// @dev Stores the outcome of trade-by-trade comparison
    struct BetResolution {
        bytes32 tradesHash;        // Hash of valid trades array at resolution time
        bytes packedOutcomes;      // 1 bit per valid trade (bitpacked win/loss)
        uint256 winsCount;         // Number of trades won by creator
        uint256 validTrades;       // Total valid trades (may be < original if some cancelled)
        bool creatorWins;          // True if creator won majority
        bool isTie;                // True if exactly 50% (winsCount * 2 == validTrades)
        bool isCancelled;          // True if validTrades == 0 (all trades had bad data)
        string cancelReason;       // Optional reason if cancelled
        uint256 resolvedAt;        // Block timestamp of resolution
        address resolvedBy;        // Keeper who submitted resolution
    }

    /// @notice Dispute info structure for tracking disputes on bets
    struct DisputeInfo {
        address disputer;
        uint256 stake;
        string reason;
        uint256 raisedAt;
        uint256 resolvedAt;
        bool outcomeChanged;
        uint256 originalWinsCount;   // Original winsCount from resolution
        uint256 originalValidTrades; // Original validTrades from resolution
    }

    // ============ State Variables ============

    /// @notice Reference to AgiArenaCore address
    address public immutable AGIARENA_CORE;

    // Keeper Registry
    mapping(address => bool) public isKeeper;
    mapping(address => string) public keeperIPs;
    address[] public keepers;

    // Proposal System
    uint256 public nextProposalId;
    mapping(uint256 => KeeperProposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVotedOnProposal;

    // Resolution State (majority-wins)
    mapping(uint256 => BetResolution) public betResolutions;

    // Settlement State
    mapping(uint256 => bool) public betSettled;
    mapping(uint256 => address) public betWinner;
    mapping(uint256 => uint256) public winnerPayouts;
    mapping(uint256 => address) public betLoser;
    mapping(uint256 => uint256) public loserPayouts;
    mapping(uint256 => bool) public winningsClaimed;
    mapping(uint256 => bool) public loserClaimed;
    mapping(uint256 => bool) public isTieBet;
    uint256 public accumulatedFees;

    // Dispute State
    mapping(uint256 => DisputeInfo) public disputes;
    mapping(uint256 => bool) public isDisputed;

    // ============ Events ============

    event KeeperProposed(uint256 indexed proposalId, address indexed proposer, address keeper, bool isRemoval);
    event KeeperAdded(address indexed keeper, uint256 proposalId);
    event KeeperRemoved(address indexed keeper, uint256 proposalId);
    event KeeperIPRegistered(address indexed keeper, string ipAddress);
    event ProposalVoteCast(uint256 indexed proposalId, address indexed keeper, bool approve);

    /// @notice Emitted when a keeper submits a bet resolution
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

    /// @notice Emitted when a bet is settled
    event BetSettled(
        uint256 indexed betId,
        address indexed winner,
        address loser,
        uint256 totalPot,
        uint256 platformFee,
        uint256 winnerPayout
    );

    /// @notice Emitted when a bet is cancelled/refunded (all trades invalid)
    event BetCancelled(uint256 indexed betId, string reason);

    /// @notice Emitted when winnings are claimed
    event WinningsClaimed(uint256 indexed betId, address indexed winner, uint256 amount);

    /// @notice Emitted when platform fees are withdrawn
    event PlatformFeesWithdrawn(address indexed recipient, uint256 amount);

    // Dispute Events
    event DisputeRaised(uint256 indexed betId, address indexed disputer, uint256 stake, string reason);
    event DisputeResolved(uint256 indexed betId, bool outcomeChanged, uint256 correctedWinsCount, uint256 correctedValidTrades);
    event DisputerSlashed(address indexed disputer, uint256 amount);
    event DisputerRewarded(address indexed disputer, uint256 amount);

    // ============ Modifiers ============

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert UnauthorizedKeeper(msg.sender);
        _;
    }

    // ============ Constructor ============

    /// @notice Initialize the ResolutionDAO with the first keeper
    /// @param initialKeeper The first keeper address (typically the deployer)
    /// @param agiArenaCore The AgiArenaCore contract address
    constructor(address initialKeeper, address agiArenaCore) {
        if (initialKeeper == address(0)) revert ZeroAddress();
        if (agiArenaCore == address(0)) revert ZeroAddress();

        AGIARENA_CORE = agiArenaCore;

        // Initialize first keeper
        isKeeper[initialKeeper] = true;
        keepers.push(initialKeeper);

        // Set dispute stake based on collateral token decimals
        uint8 decimals = IERC20Metadata(address(IAgiArenaCore(agiArenaCore).COLLATERAL_TOKEN())).decimals();
        MIN_DISPUTE_STAKE = 10 * (10 ** decimals);

        emit KeeperAdded(initialKeeper, 0);
    }

    // ============ Keeper IP Registry Functions ============

    /// @notice Register or update keeper's IP:port for off-chain discovery
    function registerKeeperIP(string memory ipAddress) external nonReentrant onlyKeeper {
        if (bytes(ipAddress).length == 0) revert EmptyIPAddress();
        keeperIPs[msg.sender] = ipAddress;
        emit KeeperIPRegistered(msg.sender, ipAddress);
    }

    // ============ Keeper Governance Functions ============

    /// @notice Propose a new keeper to be added
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
    function proposeKeeperRemoval(address keeper) external nonReentrant onlyKeeper returns (uint256 proposalId) {
        if (!isKeeper[keeper]) revert KeeperNotFound(keeper);
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
    function voteOnKeeperProposal(uint256 proposalId, bool approve) external nonReentrant onlyKeeper {
        KeeperProposal storage proposal = proposals[proposalId];

        if (proposal.createdAt == 0) revert ProposalNotFound(proposalId);
        if (proposal.executed) revert ProposalAlreadyExecuted(proposalId);
        if (block.timestamp > proposal.createdAt + PROPOSAL_EXPIRY) revert ProposalExpired(proposalId);
        if (hasVotedOnProposal[proposalId][msg.sender]) revert AlreadyVotedOnProposal(msg.sender, proposalId);

        hasVotedOnProposal[proposalId][msg.sender] = true;

        if (approve) {
            proposal.votesFor++;
        } else {
            proposal.votesAgainst++;
        }

        emit ProposalVoteCast(proposalId, msg.sender, approve);
    }

    /// @notice Execute a keeper proposal if majority approves
    function executeKeeperProposal(uint256 proposalId) external nonReentrant onlyKeeper {
        KeeperProposal storage proposal = proposals[proposalId];

        if (proposal.createdAt == 0) revert ProposalNotFound(proposalId);
        if (proposal.executed) revert ProposalAlreadyExecuted(proposalId);
        if (block.timestamp > proposal.createdAt + PROPOSAL_EXPIRY) revert ProposalExpired(proposalId);

        uint256 totalKeepers = keepers.length;
        uint256 requiredVotes = totalKeepers;

        if (proposal.votesFor < requiredVotes) revert QuorumNotReached(proposalId);

        proposal.executed = true;

        if (proposal.isRemoval) {
            _removeKeeper(proposal.keeper);
            emit KeeperRemoved(proposal.keeper, proposalId);
        } else {
            isKeeper[proposal.keeper] = true;
            keepers.push(proposal.keeper);
            emit KeeperAdded(proposal.keeper, proposalId);
        }
    }

    // ============ Resolution Functions (Majority-Wins) ============

    /// @notice Submit resolution for a bet (leader keeper submits after off-chain consensus)
    /// @param betId The bet ID to resolve
    /// @param tradesHash Hash of valid trades array at resolution time
    /// @param packedOutcomes Bitpacked outcomes (1 bit per trade: 1=creator win, 0=creator loss)
    /// @param winsCount Number of trades won by creator
    /// @param validTrades Total number of valid trades
    /// @param creatorWins True if creator won majority (winsCount * 2 > validTrades)
    /// @param isTie True if exactly 50% (winsCount * 2 == validTrades)
    /// @param isCancelled True if all trades were invalid (validTrades == 0)
    /// @param cancelReason Reason for cancellation (if isCancelled)
    function submitResolution(
        uint256 betId,
        bytes32 tradesHash,
        bytes calldata packedOutcomes,
        uint256 winsCount,
        uint256 validTrades,
        bool creatorWins,
        bool isTie,
        bool isCancelled,
        string calldata cancelReason
    ) external nonReentrant onlyKeeper {
        // Validate bet not already resolved
        if (betResolutions[betId].resolvedAt != 0) revert BetAlreadyResolved(betId);

        // Validate resolution data consistency
        if (isCancelled) {
            if (validTrades != 0) revert InvalidCancelledCondition();
        } else {
            if (validTrades == 0) revert InvalidResolutionData();

            // Validate tie condition
            if (isTie) {
                if (winsCount * 2 != validTrades) revert InvalidTieCondition();
            }

            // Validate creatorWins condition
            if (!isTie) {
                bool expectedCreatorWins = winsCount * 2 > validTrades;
                if (creatorWins != expectedCreatorWins) revert InvalidCreatorWinsCondition();
            }
        }

        // Validate cancel reason length
        if (bytes(cancelReason).length > MAX_REASON_LENGTH) {
            revert DisputeReasonTooLong(bytes(cancelReason).length, MAX_REASON_LENGTH);
        }

        // Store resolution
        betResolutions[betId] = BetResolution({
            tradesHash: tradesHash,
            packedOutcomes: packedOutcomes,
            winsCount: winsCount,
            validTrades: validTrades,
            creatorWins: creatorWins,
            isTie: isTie,
            isCancelled: isCancelled,
            cancelReason: cancelReason,
            resolvedAt: block.timestamp,
            resolvedBy: msg.sender
        });

        emit BetResolutionSubmitted(
            betId,
            msg.sender,
            tradesHash,
            winsCount,
            validTrades,
            creatorWins,
            isTie,
            isCancelled
        );
    }

    // ============ Settlement Functions ============

    /// @notice Settle a bet after resolution - permissionless, anyone can call
    function settleBet(uint256 betId) external nonReentrant {
        _settleBetInternal(betId);
    }

    /// @notice Batch settle multiple bets in one transaction
    function settleBets(uint256[] calldata betIds) external nonReentrant {
        require(betIds.length <= MAX_BATCH_SIZE, "Batch too large");
        for (uint256 i = 0; i < betIds.length; i++) {
            _settleBetInternalSafe(betIds[i]);
        }
    }

    function _settleBetInternal(uint256 betId) internal {
        BetResolution storage resolution = betResolutions[betId];

        // Check resolution exists
        if (resolution.resolvedAt == 0) revert BetNotResolved(betId);

        // Check not already settled
        if (betSettled[betId]) revert BetAlreadySettled(betId);

        // Check dispute state
        if (isDisputed[betId]) {
            if (disputes[betId].resolvedAt == 0) revert DisputePending(betId);
        }

        _executeSettlement(betId);
    }

    function _settleBetInternalSafe(uint256 betId) internal {
        BetResolution storage resolution = betResolutions[betId];

        if (resolution.resolvedAt == 0) return;
        if (betSettled[betId]) return;
        if (isDisputed[betId] && disputes[betId].resolvedAt == 0) return;

        _executeSettlement(betId);
    }

    function _executeSettlement(uint256 betId) internal {
        BetResolution storage resolution = betResolutions[betId];

        // Get bet data from AgiArenaCore
        (uint256 creatorStake, uint256 matchedAmount, address creator, address filler) = _getBetParties(betId);

        // Handle cancelled case (all trades invalid) - refund both
        if (resolution.isCancelled) {
            _refundBoth(betId, creatorStake, matchedAmount, creator, filler, resolution.cancelReason);
            return;
        }

        // Calculate total pot and fees (used by tie and win cases)
        uint256 totalPot = creatorStake + matchedAmount;
        uint256 platformFee = (totalPot * PLATFORM_FEE_BPS) / 10000;

        // Handle tie case (exact 50%) - refund both with proportional fee
        if (resolution.isTie) {
            _handleTieSettlement(betId, creatorStake, matchedAmount, platformFee, totalPot, creator, filler);
            return;
        }

        // Handle normal win case
        // If disputed and outcome changed, use the corrected outcome
        bool creatorWins = resolution.creatorWins;
        if (isDisputed[betId] && disputes[betId].outcomeChanged) {
            // Recalculate from corrected values
            DisputeInfo storage dispute = disputes[betId];
            creatorWins = dispute.originalWinsCount * 2 > dispute.originalValidTrades;
            creatorWins = !creatorWins; // Flip because outcome changed
        }

        _handleWinnerSettlement(betId, creatorWins, platformFee, totalPot, creator, filler);
    }

    function _getBetParties(uint256 betId)
        internal
        view
        returns (uint256 creatorStake, uint256 matchedAmount, address creator, address filler)
    {
        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        IAgiArenaCore.BetStatus status;
        (
            , // tradesHash
            , // snapshotId
            , // jsonStorageRef
            creatorStake,
            , // requiredMatch
            matchedAmount,
            , // oddsBps
            creator,
            status,
            , // createdAt
              // resolutionDeadline
        ) = core.bets(betId);

        if (status != IAgiArenaCore.BetStatus.FullyMatched && status != IAgiArenaCore.BetStatus.PartiallyMatched) {
            revert InvalidBetStatus(betId);
        }

        IAgiArenaCore.Fill[] memory fills = core.getBetFills(betId);
        if (fills.length == 0) {
            revert NoFiller(betId);
        }
        filler = fills[0].filler;
    }

    function _refundBoth(
        uint256 betId,
        uint256 creatorStake,
        uint256 matchedAmount,
        address creator,
        address filler,
        string memory reason
    ) internal {
        betSettled[betId] = true;
        isTieBet[betId] = true;
        betWinner[betId] = creator;
        winnerPayouts[betId] = creatorStake;
        betLoser[betId] = filler;
        loserPayouts[betId] = matchedAmount;

        emit BetCancelled(betId, reason);
    }

    function _handleTieSettlement(
        uint256 betId,
        uint256 creatorStake,
        uint256 matchedAmount,
        uint256 platformFee,
        uint256 totalPot,
        address creator,
        address filler
    ) internal {
        uint256 creatorFeeShare = (platformFee * creatorStake) / totalPot;
        uint256 fillerFeeShare = platformFee - creatorFeeShare;

        uint256 creatorReturn = creatorStake - creatorFeeShare;
        uint256 fillerReturn = matchedAmount - fillerFeeShare;

        betSettled[betId] = true;
        isTieBet[betId] = true;
        betWinner[betId] = creator;
        winnerPayouts[betId] = creatorReturn;
        betLoser[betId] = filler;
        loserPayouts[betId] = fillerReturn;
        accumulatedFees += platformFee;

        emit BetSettled(betId, creator, filler, totalPot, platformFee, creatorReturn);
    }

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

        betSettled[betId] = true;
        betWinner[betId] = winner;
        winnerPayouts[betId] = winnerPayout;
        accumulatedFees += platformFee;

        emit BetSettled(betId, winner, loser, totalPot, platformFee, winnerPayout);
    }

    /// @notice Claim winnings for a settled bet
    function claimWinnings(uint256 betId) external nonReentrant {
        if (!betSettled[betId]) revert InvalidBetStatus(betId);

        uint256 payout;
        bool isWinner = betWinner[betId] == msg.sender;
        bool isLoserInTie = isTieBet[betId] && betLoser[betId] == msg.sender;

        if (isWinner) {
            if (winningsClaimed[betId]) revert NoWinningsAvailable(betId);
            payout = winnerPayouts[betId];
            if (payout == 0) revert NoWinningsAvailable(betId);
            winningsClaimed[betId] = true;
        } else if (isLoserInTie) {
            if (loserClaimed[betId]) revert NoWinningsAvailable(betId);
            payout = loserPayouts[betId];
            if (payout == 0) revert NoWinningsAvailable(betId);
            loserClaimed[betId] = true;
        } else {
            revert NotWinner(msg.sender, betId);
        }

        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        IERC20 collateral = core.COLLATERAL_TOKEN();
        collateral.safeTransferFrom(AGIARENA_CORE, msg.sender, payout);

        emit WinningsClaimed(betId, msg.sender, payout);
    }

    /// @notice Withdraw accumulated platform fees
    function withdrawPlatformFees() external nonReentrant {
        uint256 fees = accumulatedFees;
        if (fees == 0) revert NoWinningsAvailable(0);

        accumulatedFees = 0;

        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        address feeRecipient = core.FEE_RECIPIENT();
        IERC20 collateral = core.COLLATERAL_TOKEN();
        collateral.safeTransferFrom(AGIARENA_CORE, feeRecipient, fees);

        emit PlatformFeesWithdrawn(feeRecipient, fees);
    }

    // ============ Dispute Functions ============

    /// @notice Raise a dispute on a bet within the dispute window
    function raiseDispute(
        uint256 betId,
        uint256 stakeAmount,
        string calldata reason
    ) external nonReentrant {
        BetResolution storage resolution = betResolutions[betId];

        if (resolution.resolvedAt == 0) revert BetNotResolved(betId);
        if (betSettled[betId]) revert BetAlreadySettled(betId);
        if (isDisputed[betId]) revert DisputeAlreadyRaised(betId);

        uint256 deadline = resolution.resolvedAt + DISPUTE_WINDOW;
        if (block.timestamp > deadline) {
            revert DisputeWindowExpired(betId, resolution.resolvedAt, deadline);
        }

        if (stakeAmount < MIN_DISPUTE_STAKE) {
            revert InsufficientDisputeStake(stakeAmount, MIN_DISPUTE_STAKE);
        }

        if (bytes(reason).length == 0) revert DisputeReasonRequired();
        if (bytes(reason).length > MAX_REASON_LENGTH) {
            revert DisputeReasonTooLong(bytes(reason).length, MAX_REASON_LENGTH);
        }

        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        IERC20 collateral = core.COLLATERAL_TOKEN();
        collateral.safeTransferFrom(msg.sender, address(this), stakeAmount);

        isDisputed[betId] = true;
        disputes[betId] = DisputeInfo({
            disputer: msg.sender,
            stake: stakeAmount,
            reason: reason,
            raisedAt: block.timestamp,
            resolvedAt: 0,
            outcomeChanged: false,
            originalWinsCount: resolution.winsCount,
            originalValidTrades: resolution.validTrades
        });

        emit DisputeRaised(betId, msg.sender, stakeAmount, reason);
    }

    /// @notice Resolve a dispute with recalculated win/loss counts
    function resolveDisputeWithRecalculation(
        uint256 betId,
        uint256 correctedWinsCount,
        uint256 correctedValidTrades,
        bool creatorWins
    ) external nonReentrant onlyKeeper {
        if (!isDisputed[betId]) revert BetNotDisputed(betId);
        if (disputes[betId].resolvedAt > 0) revert DisputeAlreadyResolved(betId);

        DisputeInfo storage dispute = disputes[betId];
        BetResolution storage resolution = betResolutions[betId];

        // Determine if outcome changed
        bool originalCreatorWins = resolution.creatorWins;
        bool outcomeChanged = (creatorWins != originalCreatorWins);

        // Update dispute info
        dispute.outcomeChanged = outcomeChanged;
        dispute.resolvedAt = block.timestamp;

        // Update resolution with corrected values if outcome changed
        if (outcomeChanged) {
            resolution.winsCount = correctedWinsCount;
            resolution.validTrades = correctedValidTrades;
            resolution.creatorWins = creatorWins;
            resolution.isTie = (correctedWinsCount * 2 == correctedValidTrades);
        }

        emit DisputeResolved(betId, outcomeChanged, correctedWinsCount, correctedValidTrades);
    }

    /// @notice Slash disputer stake for invalid dispute
    function slashDisputer(uint256 betId) external nonReentrant onlyKeeper {
        if (!isDisputed[betId]) revert BetNotDisputed(betId);

        DisputeInfo storage dispute = disputes[betId];
        if (dispute.resolvedAt == 0) revert DisputePending(betId);
        if (dispute.outcomeChanged) revert DisputeOutcomeChanged(betId);
        if (dispute.stake == 0) revert DisputeStakeAlreadyProcessed(betId);

        uint256 stakeAmount = dispute.stake;
        dispute.stake = 0;
        accumulatedFees += stakeAmount;

        emit DisputerSlashed(dispute.disputer, stakeAmount);
    }

    /// @notice Refund disputer stake plus reward for valid dispute
    function refundDisputer(uint256 betId) external nonReentrant {
        if (!isDisputed[betId]) revert BetNotDisputed(betId);

        DisputeInfo storage dispute = disputes[betId];
        if (dispute.resolvedAt == 0) revert DisputePending(betId);
        if (!dispute.outcomeChanged) revert DisputeOutcomeUnchanged(betId);
        if (dispute.stake == 0) revert DisputeStakeAlreadyProcessed(betId);

        uint256 stakeAmount = dispute.stake;

        (uint256 creatorStake, uint256 matchedAmount, , ) = _getBetParties(betId);
        uint256 totalPot = creatorStake + matchedAmount;
        uint256 reward = (totalPot * DISPUTE_REWARD_BPS) / 10000;

        dispute.stake = 0;

        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        IERC20 collateral = core.COLLATERAL_TOKEN();

        collateral.safeTransfer(dispute.disputer, stakeAmount);
        if (reward > 0) {
            collateral.safeTransferFrom(AGIARENA_CORE, dispute.disputer, reward);
        }

        emit DisputerRewarded(dispute.disputer, stakeAmount + reward);
    }

    // ============ View Functions ============

    function getKeeperCount() external view returns (uint256) {
        return keepers.length;
    }

    function getKeeperAtIndex(uint256 index) external view returns (address) {
        return keepers[index];
    }

    function getKeeperIP(address keeper) external view returns (string memory) {
        return keeperIPs[keeper];
    }

    function getProposal(uint256 proposalId) external view returns (KeeperProposal memory) {
        return proposals[proposalId];
    }

    function getBetResolution(uint256 betId) external view returns (BetResolution memory) {
        return betResolutions[betId];
    }

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

    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }

    function canSettleBet(uint256 betId) external view returns (bool) {
        if (betResolutions[betId].resolvedAt == 0 || betSettled[betId]) {
            return false;
        }
        if (isDisputed[betId] && disputes[betId].resolvedAt == 0) {
            return false;
        }

        IAgiArenaCore core = IAgiArenaCore(AGIARENA_CORE);
        (, , , , , , , , IAgiArenaCore.BetStatus status,,) = core.bets(betId);

        return status == IAgiArenaCore.BetStatus.FullyMatched ||
               status == IAgiArenaCore.BetStatus.PartiallyMatched;
    }

    function getDisputeInfo(uint256 betId) external view returns (DisputeInfo memory) {
        return disputes[betId];
    }

    function canRaiseDispute(uint256 betId) external view returns (bool) {
        if (betResolutions[betId].resolvedAt == 0) return false;
        if (betSettled[betId]) return false;
        if (isDisputed[betId]) return false;

        uint256 deadline = betResolutions[betId].resolvedAt + DISPUTE_WINDOW;
        if (block.timestamp > deadline) return false;

        return true;
    }

    function getDisputeDeadline(uint256 betId) external view returns (uint256) {
        if (betResolutions[betId].resolvedAt == 0) return 0;
        return betResolutions[betId].resolvedAt + DISPUTE_WINDOW;
    }

    // ============ Internal Functions ============

    function _removeKeeper(address keeper) internal {
        isKeeper[keeper] = false;
        delete keeperIPs[keeper];

        for (uint256 i = 0; i < keepers.length; i++) {
            if (keepers[i] == keeper) {
                keepers[i] = keepers[keepers.length - 1];
                keepers.pop();
                break;
            }
        }
    }
}
