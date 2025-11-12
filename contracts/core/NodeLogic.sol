// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 * Lola / Protola — Node Logic (Relayer Manager)
 *
 * Responsibilities:
 * - Node registration, staking, and heartbeats.
 * - Oracle-based route advice and work receipt verification (EIP-712).
 * - Per-relayer reimbursement rate-limits.
 * - Calls into LolaCore to trigger reimbursements from Vault2.
 *
 * This contract does NOT hold user funds. It coordinates relayers and oracles
 * and is intended to be set as `relayerManager` in LolaCore.
 */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

interface ILolaCore {
    function reimburseRelayer(address payable relayer, uint256 amount) external;
}

contract LolaNodeManager is AccessControl, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // =========================================================
    // Roles
    // =========================================================

    bytes32 public constant ADMIN_ROLE   = keccak256("ADMIN_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant PAUSER_ROLE  = keccak256("PAUSER_ROLE");
    bytes32 public constant ORACLE_ROLE  = keccak256("ORACLE_ROLE");

    // =========================================================
    // Errors
    // =========================================================

    error NotRegistered();
    error AlreadyRegistered();
    error StakeTooLow();
    error CooldownActive();
    error NothingToWithdraw();
    error ReceiptExpired();
    error InvalidSignature();
    error AdviceExpired();
    error Duplicate();
    error ZeroAddress();
    error EndpointTooLong();
    error QuorumTooHigh();
    error DuplicateSigner();
    error RateLimitExceeded();

    // =========================================================
    // External Dependencies
    // =========================================================

    /// @notice Token used for node staking.
    IERC20 public immutable stakingToken;

    /// @notice LolaCore contract used to reimburse relayers.
    /// @dev This contract must be set as `relayerManager` in LolaCore.
    ILolaCore public core;

    // =========================================================
    // Parameters
    // =========================================================

    uint256 public minStake;
    uint256 public withdrawCooldown;
    uint256 public heartbeatWindow;
    uint256 public maxAdviceTTL;
    uint256 public maxReceiptTTL;
    uint256 public maxEndpointBytes; // calldata guard (default 256)
    uint8   public oracleQuorum;     // required oracle signatures (default 1)

    // Reimbursement rate-limit: simple rolling bucket per relayer.
    struct RateLimit {
        uint64 windowStart;     // unix timestamp aligned to window
        uint256 amountInWindow; // wei reimbursed in current window
    }

    uint64  public rlWindowSeconds;     // default 3600 (1h)
    uint256 public rlMaxWeiPerWindow;   // admin-defined cap (0 = disabled)

    // =========================================================
    // Node State
    // =========================================================

    enum NodeStatus {
        Inactive,
        Active,
        Slashed
    }

    struct Node {
        address operator;
        uint256 stake;
        uint64  lastHeartbeat;
        uint64  withdrawAt;
        NodeStatus status;
        string  endpoint;
        uint256 supportedChains; // bitmask or encoded representation
        uint96  reputation;
    }

    /// @notice nodeId => Node details
    mapping(bytes32 => Node) public nodes;

    /// @notice operator => nodeId
    mapping(address => bytes32) public nodeOf;

    // =========================================================
    // Replay Protection
    // =========================================================

    mapping(bytes32 => bool) public usedAdviceIds;
    mapping(bytes32 => bool) public usedWorkReceipts;

    // Per-relayer rate-limits
    mapping(address => RateLimit) internal _rl;

    // =========================================================
    // EIP-712 Types
    // =========================================================

    struct RouteAdvice {
        uint256 srcChainId;
        uint256 dstChainId;
        uint256 baseFeeWei;
        uint256 congestion;
        uint256 deadline;
        uint256 adviceId;
    }

    struct WorkReceipt {
        bytes32 workId;
        address relayer;
        uint256 nativeWei;
        uint256 gasUsed;
        uint256 gasPriceWei;
        uint256 deadline;
    }

    bytes32 private constant ROUTE_ADVICE_TYPEHASH =
        keccak256(
            "RouteAdvice(uint256 srcChainId,uint256 dstChainId,uint256 baseFeeWei,uint256 congestion,uint256 deadline,uint256 adviceId)"
        );

    bytes32 private constant WORK_RECEIPT_TYPEHASH =
        keccak256(
            "WorkReceipt(bytes32 workId,address relayer,uint256 nativeWei,uint256 gasUsed,uint256 gasPriceWei,uint256 deadline)"
        );

    // =========================================================
    // Events
    // =========================================================

    event CoreUpdated(address core);
    event ParamsUpdated(
        uint256 minStake,
        uint256 withdrawCooldown,
        uint256 heartbeatWindow,
        uint256 maxAdviceTTL,
        uint256 maxReceiptTTL,
        uint256 maxEndpointBytes,
        uint8   oracleQuorum,
        uint64  rlWindowSeconds,
        uint256 rlMaxWeiPerWindow
    );

    event NodeRegistered(
        bytes32 indexed nodeId,
        address indexed operator,
        uint256 stake,
        string endpoint,
        uint256 supportedChains
    );
    event NodeActivated(bytes32 indexed nodeId);
    event NodeUpdated(bytes32 indexed nodeId, string endpoint, uint256 supportedChains);
    event Heartbeat(bytes32 indexed nodeId, uint64 timestamp);
    event ReputationChanged(bytes32 indexed nodeId, uint96 newScore);
    event StakeAdded(bytes32 indexed nodeId, uint256 amount, uint256 newStake);
    event WithdrawRequested(bytes32 indexed nodeId, uint64 availableAt);
    event StakeWithdrawn(bytes32 indexed nodeId, uint256 amount, address to);
    event Slashed(bytes32 indexed nodeId, uint256 amount, string reason);

    event AdviceConsumed(bytes32 indexed adviceId, address indexed relayer);
    event Reimbursed(bytes32 indexed workId, address indexed relayer, uint256 nativeWei);

    // =========================================================
    // Constructor
    // =========================================================

    constructor(
        address _admin,
        address _stakingToken,
        address _core,
        uint256 _minStake
    )
        EIP712("LolaNodeManager", "2") // version bumped after hardening
    {
        if (_admin == address(0) || _stakingToken == address(0) || _core == address(0)) {
            revert ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(SLASHER_ROLE, _admin);
        _grantRole(ORACLE_ROLE, _admin);

        stakingToken = IERC20(_stakingToken);
        core = ILolaCore(_core);

        minStake = _minStake;
        withdrawCooldown = 2 days;
        heartbeatWindow = 1 hours;
        maxAdviceTTL = 30 minutes;
        maxReceiptTTL = 30 minutes;
        maxEndpointBytes = 256;
        oracleQuorum = 1;

        rlWindowSeconds = 3600;
        rlMaxWeiPerWindow = 0; // 0 = disabled
    }

    // =========================================================
    // Admin Configuration
    // =========================================================

    /// @notice Updates the LolaCore contract used for reimbursements.
    function setCore(address _core) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (_core == address(0)) revert ZeroAddress();
        core = ILolaCore(_core);
        emit CoreUpdated(_core);
    }

    /// @notice Updates general parameters for nodes, oracles, and rate-limits.
    function setParams(
        uint256 _minStake,
        uint256 _withdrawCooldown,
        uint256 _heartbeatWindow,
        uint256 _maxAdviceTTL,
        uint256 _maxReceiptTTL,
        uint256 _maxEndpointBytes,
        uint8   _oracleQuorum,
        uint64  _rlWindowSeconds,
        uint256 _rlMaxWeiPerWindow
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (_oracleQuorum == 0) {
            _oracleQuorum = 1;
        }
        if (_oracleQuorum > 20) revert QuorumTooHigh();

        minStake = _minStake;
        withdrawCooldown = _withdrawCooldown;
        heartbeatWindow = _heartbeatWindow;
        maxAdviceTTL = _maxAdviceTTL;
        maxReceiptTTL = _maxReceiptTTL;
        maxEndpointBytes = _maxEndpointBytes;
        oracleQuorum = _oracleQuorum;
        rlWindowSeconds = _rlWindowSeconds;
        rlMaxWeiPerWindow = _rlMaxWeiPerWindow;

        emit ParamsUpdated(
            _minStake,
            _withdrawCooldown,
            _heartbeatWindow,
            _maxAdviceTTL,
            _maxReceiptTTL,
            _maxEndpointBytes,
            _oracleQuorum,
            _rlWindowSeconds,
            _rlMaxWeiPerWindow
        );
    }

    /// @notice Pauses node operations and reimbursements.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses node operations and reimbursements.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================
    // Node Registration & Staking
    // =========================================================

    /// @notice Registers a new node and stakes the required amount.
    /// @param endpoint Public endpoint for the node (length-limited).
    /// @param supportedChains Encoded representation of supported chains.
    /// @param salt Optional salt to avoid theoretical nodeId collisions.
    function registerNode(
        string calldata endpoint,
        uint256 supportedChains,
        bytes32 salt
    ) external nonReentrant whenNotPaused {
        if (bytes(endpoint).length > maxEndpointBytes) revert EndpointTooLong();
        if (nodeOf[msg.sender] != bytes32(0)) revert AlreadyRegistered();

        bytes32 nodeId = keccak256(abi.encodePacked(msg.sender, salt));
        if (nodes[nodeId].operator != address(0)) revert Duplicate();

        // Pull stake
        if (minStake > 0) {
            stakingToken.safeTransferFrom(msg.sender, address(this), minStake);
        }

        nodes[nodeId] = Node({
            operator: msg.sender,
            stake: minStake,
            lastHeartbeat: uint64(block.timestamp),
            withdrawAt: 0,
            status: NodeStatus.Active,
            endpoint: endpoint,
            supportedChains: supportedChains,
            reputation: 0
        });

        nodeOf[msg.sender] = nodeId;

        emit NodeRegistered(nodeId, msg.sender, minStake, endpoint, supportedChains);
        emit NodeActivated(nodeId);
    }

    /// @notice Increases stake for an existing node.
    function addStake(bytes32 nodeId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        Node storage n = nodes[nodeId];
        if (n.operator == address(0)) revert NotRegistered();
        if (n.operator != msg.sender) revert NotRegistered(); // only operator can add

        require(amount > 0, "AMOUNT_ZERO");

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        n.stake += amount;

        emit StakeAdded(nodeId, amount, n.stake);
    }

    /// @notice Updates endpoint or supported chains for a node.
    function updateNode(
        bytes32 nodeId,
        string calldata endpoint,
        uint256 supportedChains
    ) external nonReentrant whenNotPaused {
        Node storage n = nodes[nodeId];
        if (n.operator == address(0)) revert NotRegistered();
        if (n.operator != msg.sender) revert NotRegistered();

        if (bytes(endpoint).length > maxEndpointBytes) revert EndpointTooLong();

        n.endpoint = endpoint;
        n.supportedChains = supportedChains;

        emit NodeUpdated(nodeId, endpoint, supportedChains);
    }

    /// @notice Heartbeat to signal node liveness.
    function heartbeat(bytes32 nodeId) external nonReentrant whenNotPaused {
        Node storage n = nodes[nodeId];
        if (n.operator == address(0)) revert NotRegistered();
        if (n.operator != msg.sender) revert NotRegistered();

        n.lastHeartbeat = uint64(block.timestamp);
        emit Heartbeat(nodeId, n.lastHeartbeat);
    }

    /// @notice Requests withdrawal of a node's stake, subject to cooldown.
    function requestWithdraw(bytes32 nodeId) external nonReentrant whenNotPaused {
        Node storage n = nodes[nodeId];
        if (n.operator == address(0)) revert NotRegistered();
        if (n.operator != msg.sender) revert NotRegistered();
        if (n.stake == 0) revert NothingToWithdraw();

        if (n.withdrawAt != 0 && n.withdrawAt > block.timestamp) revert CooldownActive();

        n.withdrawAt = uint64(block.timestamp + withdrawCooldown);
        n.status = NodeStatus.Inactive;

        emit WithdrawRequested(nodeId, n.withdrawAt);
    }

    /// @notice Withdraws stake after cooldown.
    function withdrawStake(bytes32 nodeId, address to)
        external
        nonReentrant
    {
        Node storage n = nodes[nodeId];
        if (n.operator == address(0)) revert NotRegistered();
        if (n.operator != msg.sender) revert NotRegistered();
        if (n.withdrawAt == 0 || block.timestamp < n.withdrawAt) revert CooldownActive();
        if (n.stake == 0) revert NothingToWithdraw();
        if (to == address(0)) revert ZeroAddress();

        uint256 amount = n.stake;
        n.stake = 0;

        stakingToken.safeTransfer(to, amount);

        emit StakeWithdrawn(nodeId, amount, to);
    }

    // =========================================================
    // Reputation & Slashing
    // =========================================================

    /// @notice Updates node reputation score.
    function setReputation(bytes32 nodeId, uint96 newScore)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        Node storage n = nodes[nodeId];
        if (n.operator == address(0)) revert NotRegistered();

        n.reputation = newScore;
        emit ReputationChanged(nodeId, newScore);
    }

    /// @notice Slashes a node's stake for misbehavior.
    function slash(
        bytes32 nodeId,
        uint256 amount,
        string calldata reason
    ) external onlyRole(SLASHER_ROLE) nonReentrant {
        Node storage n = nodes[nodeId];
        if (n.operator == address(0)) revert NotRegistered();
        if (amount == 0 || amount > n.stake) revert StakeTooLow();

        n.stake -= amount;
        n.status = NodeStatus.Slashed;

        emit Slashed(nodeId, amount, reason);
    }

    // =========================================================
    // EIP-712 Helpers
    // =========================================================

    function _hashRouteAdvice(RouteAdvice memory advice) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        ROUTE_ADVICE_TYPEHASH,
                        advice.srcChainId,
                        advice.dstChainId,
                        advice.baseFeeWei,
                        advice.congestion,
                        advice.deadline,
                        advice.adviceId
                    )
                )
            );
    }

    function _hashWorkReceipt(WorkReceipt memory receipt) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        WORK_RECEIPT_TYPEHASH,
                        receipt.workId,
                        receipt.relayer,
                        receipt.nativeWei,
                        receipt.gasUsed,
                        receipt.gasPriceWei,
                        receipt.deadline
                    )
                )
            );
    }

    /// @dev Verifies oracle signatures for a given digest and enforces quorum.
    function _verifyOracleSignatures(bytes32 digest, bytes[] calldata signatures)
        internal
        view
    {
        if (signatures.length < oracleQuorum) {
            revert InvalidSignature();
        }

        // track seen signers to prevent duplicates
        address[] memory seen = new address[](signatures.length);
        uint256 validCount = 0;

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = digest.recover(signatures[i]);

            if (!hasRole(ORACLE_ROLE, signer)) {
                revert InvalidSignature();
            }

            // check duplicates
            for (uint256 j = 0; j < validCount; j++) {
                if (seen[j] == signer) revert DuplicateSigner();
            }

            seen[validCount] = signer;
            validCount++;
        }

        if (validCount < oracleQuorum) {
            revert InvalidSignature();
        }
    }

    // =========================================================
    // Route Advice Consumption
    // =========================================================

    /// @notice Marks a route advice as consumed after oracle validation.
    /// @dev This does not move funds; it is an on-chain record that a particular
    ///      adviceId has been accepted. Off-chain systems can reference this.
    function consumeRouteAdvice(
        RouteAdvice calldata advice,
        bytes[] calldata oracleSignatures
    ) external nonReentrant whenNotPaused {
        if (advice.deadline + maxAdviceTTL < block.timestamp) revert AdviceExpired();

        bytes32 adviceKey = keccak256(abi.encodePacked(advice.adviceId));
        if (usedAdviceIds[adviceKey]) revert Duplicate();

        bytes32 digest = _hashRouteAdvice(advice);
        _verifyOracleSignatures(digest, oracleSignatures);

        usedAdviceIds[adviceKey] = true;

        emit AdviceConsumed(adviceKey, msg.sender);
    }

    // =========================================================
    // Reimbursement Flow (via LolaCore)
    // =========================================================

    /// @notice Processes a work receipt and requests reimbursement via LolaCore.
    /// @dev Enforces:
    ///      - receipt TTL,
    ///      - replay protection,
    ///      - oracle quorum signatures,
    ///      - per-relayer rate-limits,
    ///      then calls `core.reimburseRelayer`.
    function reimburseRelayer(
        WorkReceipt calldata receipt,
        bytes[] calldata oracleSignatures
    ) external nonReentrant whenNotPaused {
        if (receipt.deadline + maxReceiptTTL < block.timestamp) {
            revert ReceiptExpired();
        }

        if (receipt.relayer == address(0)) revert ZeroAddress();
        if (receipt.nativeWei == 0) revert RateLimitExceeded(); // treat 0 as invalid

        if (usedWorkReceipts[receipt.workId]) revert Duplicate();

        bytes32 digest = _hashWorkReceipt(receipt);
        _verifyOracleSignatures(digest, oracleSignatures);

        // Mark receipt as used.
        usedWorkReceipts[receipt.workId] = true;

        // Rate limit per relayer.
        _applyRateLimit(receipt.relayer, receipt.nativeWei);

        // Call into LolaCore; LolaCore enforces `onlyRelayerManager` and then
        // calls Vault2 to reimburse native gas.
        core.reimburseRelayer(payable(receipt.relayer), receipt.nativeWei);

        emit Reimbursed(receipt.workId, receipt.relayer, receipt.nativeWei);
    }

    function _applyRateLimit(address relayer, uint256 amountWei) internal {
        if (rlMaxWeiPerWindow == 0) {
            // rate limiting disabled
            return;
        }

        RateLimit storage rl = _rl[relayer];

        uint64 nowTs = uint64(block.timestamp);
        uint64 windowStart = rl.windowStart;

        if (windowStart == 0 || nowTs >= windowStart + rlWindowSeconds) {
            // reset window
            rl.windowStart = nowTs;
            rl.amountInWindow = amountWei;
        } else {
            uint256 newAmount = rl.amountInWindow + amountWei;
            if (newAmount > rlMaxWeiPerWindow) revert RateLimitExceeded();
            rl.amountInWindow = newAmount;
        }
    }
}