// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title LolaCore
/// @notice Core router and fee engine for the Lola Protocol.
/// @dev LolaCore is a deterministic on-chain executor:
///      - validates user transactions,
///      - computes micro-fees,
///      - routes funds between Vault1 (liquidity) and Vault2 (fee / reimburse),
///      - and processes relayer reimbursements.
///      Off-chain nodes and a separate NodeManager contract handle
///      route selection, oracle quorums, and relayer policy.
contract LolaCore is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================
    // Vault Interfaces
    // =========================================================

    interface ILolaVault1 {
        function credit(address token, uint256 amount) external returns (bool);
        function vaultBalance(address token) external view returns (uint256);
    }

    interface ILolaVault2 {
        function credit(address token, uint256 amount) external returns (bool);
        function reimburseNative(address payable to, uint256 amount) external returns (bool);
        function vaultBalance(address token) external view returns (uint256);
    }

    ILolaVault1 public vault1;
    ILolaVault2 public vault2;

    // =========================================================
    // Constants
    // =========================================================

    uint256 internal constant PPM_DEN = 1_000_000;
    uint256 public constant MIN_FEE_PPM = 50;   // 0.005%
    uint256 public constant MAX_FEE_PPM = 150;  // 0.015%

    // =========================================================
    // Governance & Control
    // =========================================================

    /// @notice Timelock / governance controller.
    address public timelock;

    /// @notice Contract allowed to request relayer reimbursements.
    /// @dev Intended to be set to the LolaNodeManager (relayer coordination / policy).
    address public relayerManager;

    bool public paused;

    struct FeeConfig {
        uint256 whaleThreshold;
        uint256 whaleFeePpm;
        uint256 stableFeePpm;
        uint256 volatileFeePpm;
        uint256 currentFeePpm;
        uint8 smoothingFactor;
    }

    FeeConfig public feeConfig;

    enum AssetTier {
        Unknown,
        Stable,
        Volatile
    }

    mapping(address => AssetTier) public assetProfiles;

    struct NodeRoute {
        address node;
        address vault;
        bool active;
        uint64 updatedAt;
    }

    /// @notice Optional routing hints per destination chain.
    /// @dev Off-chain nodes may use this for discovery; Core itself does not compute routes.
    mapping(uint256 => NodeRoute) public nodeRoutes;

    /// @notice Asset whitelist by chain.
    /// @dev chainId => token => allowed?
    mapping(uint256 => mapping(address => bool)) public tokenWhitelist;

    // =========================================================
    // Stats
    // =========================================================

    uint256 public totalTransactions;
    uint256 public totalValueProcessed;

    // =========================================================
    // Events
    // =========================================================

    event EmergencyPaused(address indexed by);
    event EmergencyUnpaused(address indexed by);

    event TokenWhitelisted(uint256 indexed chainId, address indexed token, bool allowed);

    event NodeRegistered(uint256 indexed chainId, address indexed node, address indexed vault);
    event NodeStatusUpdated(uint256 indexed chainId, bool active);

    event FeeApplied(
        address indexed token,
        uint256 grossAmount,
        uint256 feeAmount,
        uint256 appliedRatePpm,
        uint256 newRollingRatePpm
    );

    event TransactionProcessed(
        address indexed user,
        address indexed relayer,
        address indexed token,
        uint256 feeAmount,
        uint256 netAmount
    );

    event RelayerManagerUpdated(address indexed relayerManager);
    event RelayerReimbursed(address indexed relayer, uint256 nativeAmount);

    // =========================================================
    // Modifiers
    // =========================================================

    modifier onlyTimelock() {
        require(msg.sender == timelock, "NOT_TIMELOCK");
        _;
    }

    modifier onlyRelayerManager() {
        require(msg.sender == relayerManager, "NOT_RELAYER_MANAGER");
        _;
    }

    modifier onlyWhitelisted(uint256 chainId, address token) {
        require(tokenWhitelist[chainId][token], "TOKEN_NOT_ALLOWED");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    // =========================================================
    // Initialization
    // =========================================================

    /// @param _vault1 Address of Vault 1 (multi-asset liquidity).
    /// @param _vault2 Address of Vault 2 (micro-fee & relayer reimbursements).
    /// @param _timelock Address of the governance timelock controller.
    constructor(address _vault1, address _vault2, address _timelock) {
        require(_vault1 != address(0), "VAULT1_ZERO");
        require(_vault2 != address(0), "VAULT2_ZERO");
        require(_timelock != address(0), "TIMELOCK_ZERO");

        vault1 = ILolaVault1(_vault1);
        vault2 = ILolaVault2(_vault2);
        timelock = _timelock;

        // By default, relayerManager starts as the timelock and should be
        // updated to the LolaNodeManager contract by governance.
        relayerManager = _timelock;

        feeConfig = FeeConfig({
            whaleThreshold: 0,
            whaleFeePpm: 30,
            stableFeePpm: 80,
            volatileFeePpm: 120,
            currentFeePpm: 100,
            smoothingFactor: 4
        });
    }

    // =========================================================
    // Core Transaction Flow
    // =========================================================

    /// @notice Processes a user transaction and routes fee / net amounts.
    /// @dev Called by a relayer that has already paid gas on behalf of `user`.
    ///      Off-chain nodes and NodeManager handle route selection and relayer
    ///      coordination; Core focuses on deterministic execution.
    ///
    /// @param user The end user originating the transaction.
    /// @param token The ERC20 token being transacted.
    /// @param amount Total token amount (including fee).
    /// @param minNetAmt Minimum net amount that must be delivered post-fee.
    /// @param destChainId Destination chain identifier for whitelist enforcement.
    /// @param payload Optional metadata or cross-chain payload (reserved).
    ///
    /// @return feeAmt The micro-fee taken from `amount`.
    /// @return netAmt The amount forwarded to the relayer (msg.sender).
    function processTransaction(
        address user,
        address token,
        uint256 amount,
        uint256 minNetAmt,
        uint256 destChainId,
        bytes calldata payload
    )
        external
        whenNotPaused
        nonReentrant
        onlyWhitelisted(destChainId, token)
        returns (uint256 feeAmt, uint256 netAmt)
    {
        require(user != address(0), "USER_ZERO");
        require(amount > 0, "AMOUNT_ZERO");

        IERC20 t = IERC20(token);

        // Pull full amount from the user into Core.
        t.safeTransferFrom(user, address(this), amount);

        // Compute micro-fee and net.
        (feeAmt, netAmt) = _calculateFee(token, amount, minNetAmt);

        // Route fee → Vault 2.
        if (feeAmt > 0) {
            t.safeIncreaseAllowance(address(vault2), feeAmt);
            require(vault2.credit(token, feeAmt), "FEE_CREDIT_FAIL");
        }

        // Route net amount → relayer (msg.sender) or downstream executor.
        t.safeTransfer(msg.sender, netAmt);

        totalTransactions++;
        totalValueProcessed += amount;

        (, uint256 appliedRate, uint256 newRolling) = _previewMicroFee(token, amount);

        emit TransactionProcessed(user, msg.sender, token, feeAmt, netAmt);
        emit FeeApplied(token, amount, feeAmt, appliedRate, newRolling);

        if (payload.length > 0) {
            // Reserved for future cross-chain signaling or auxiliary data.
        }
    }

    // =========================================================
    // Relayer Reimbursement (Native)
    // =========================================================

    /// @notice Reimburses a relayer in native gas using Vault 2 funds.
    /// @dev Expected to be called only by the LolaNodeManager contract, which
    ///      enforces relayer registration, rate limits, quorums, and policies.
    ///
    /// @param relayer Relayer address to receive native gas.
    /// @param amount Native amount to reimburse (denominated in chain's gas token).
    function reimburseRelayer(address payable relayer, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyRelayerManager
    {
        require(relayer != address(0), "RELAYER_ZERO");
        require(amount > 0, "AMOUNT_ZERO");

        require(vault2.reimburseNative(relayer, amount), "REIMBURSE_FAIL");

        emit RelayerReimbursed(relayer, amount);
    }

    // =========================================================
    // Fee Computation
    // =========================================================

    /// @dev Computes the fee and net amount and enforces `minNetAmt`.
    function _calculateFee(address token, uint256 amt, uint256 minNetAmt)
        internal
        view
        returns (uint256 feeAmt, uint256 netAmt)
    {
        (feeAmt,,) = _previewMicroFee(token, amt);
        netAmt = amt - feeAmt;
        require(netAmt >= minNetAmt, "NET_TOO_LOW");
    }

    /// @dev Purely a view "preview" — does not mutate feeConfig.
    ///      Uses current config and clamped bounds to derive a micro-fee.
    function _previewMicroFee(address token, uint256 amt)
        internal
        view
        returns (uint256 feeAmt, uint256 appliedRate, uint256 nextRollingRate)
    {
        uint256 rawRate = _selectRate(token, amt);
        appliedRate = rawRate > MAX_FEE_PPM ? MAX_FEE_PPM : rawRate;

        feeAmt = Math.mulDiv(amt, appliedRate, PPM_DEN);

        uint256 smoothed =
            (feeConfig.currentFeePpm * feeConfig.smoothingFactor + appliedRate) /
            (feeConfig.smoothingFactor + 1);

        nextRollingRate = _clamp(smoothed, MIN_FEE_PPM, MAX_FEE_PPM);
    }

    /// @dev Selects the nominal fee rate based on asset profile and whale threshold.
    function _selectRate(address token, uint256 amt) internal view returns (uint256) {
        if (feeConfig.whaleThreshold != 0 && amt >= feeConfig.whaleThreshold) {
            return feeConfig.whaleFeePpm;
        }

        AssetTier profile = assetProfiles[token];
        if (profile == AssetTier.Stable) return feeConfig.stableFeePpm;
        if (profile == AssetTier.Volatile) return feeConfig.volatileFeePpm;
        return feeConfig.currentFeePpm;
    }

    /// @dev Clamps a value between `minVal` and `maxVal`.
    function _clamp(uint256 val, uint256 minVal, uint256 maxVal) internal pure returns (uint256) {
        if (val < minVal) return minVal;
        if (val > maxVal) return maxVal;
        return val;
    }

    // =========================================================
    // Governance Setters
    // =========================================================

    /// @notice Sets the relayer manager contract (e.g., LolaNodeManager).
    /// @dev Only governance can update this pointer.
    function setRelayerManager(address _relayerManager) external onlyTimelock {
        require(_relayerManager != address(0), "RELAYER_MANAGER_ZERO");
        relayerManager = _relayerManager;
        emit RelayerManagerUpdated(_relayerManager);
    }

    /// @notice Updates token whitelist for a given chain.
    function setTokenWhitelist(uint256 chainId, address token, bool allowed) external onlyTimelock {
        tokenWhitelist[chainId][token] = allowed;
        emit TokenWhitelisted(chainId, token, allowed);
    }

    /// @notice Registers or updates a node route hint for a destination chain.
    /// @dev Optional helper for off-chain routing layers; Core does not enforce this.
    function registerNodeRoute(uint256 chainId, address node, address vault, bool active)
        external
        onlyTimelock
    {
        nodeRoutes[chainId] = NodeRoute({
            node: node,
            vault: vault,
            active: active,
            updatedAt: uint64(block.timestamp)
        });

        emit NodeRegistered(chainId, node, vault);
        emit NodeStatusUpdated(chainId, active);
    }

    /// @notice Emergency pause of state-changing operations.
    function emergencyPause() external onlyTimelock {
        paused = true;
        emit EmergencyPaused(msg.sender);
    }

    /// @notice Unpause after an emergency pause.
    function emergencyUnpause() external onlyTimelock {
        paused = false;
        emit EmergencyUnpaused(msg.sender);
    }
}