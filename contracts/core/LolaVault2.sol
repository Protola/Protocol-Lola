// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title LolaVault2
/// @notice Micro-fee reserve and relayer reimbursement vault for Lola Protocol.
/// @dev This vault is write-controlled exclusively by LolaCore for fee crediting and
///      native reimbursements. Governance (timelock) may perform administrative actions.
contract LolaVault2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================
    // Governance / Roles
    // =========================================================

    /// @notice Timelock / governance controller.
    address public timelock;

    /// @notice LolaCore contract that credits fees and triggers reimbursements.
    address public core;

    /// @notice Global pause flag for state-changing operations.
    bool public paused;

    modifier onlyTimelock() {
        require(msg.sender == timelock, "NOT_TIMELOCK");
        _;
    }

    modifier onlyCore() {
        require(msg.sender == core, "NOT_CORE");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    // =========================================================
    // State
    // =========================================================

    /// @notice ERC20 fee balances tracked by token.
    mapping(address => uint256) private tokenBalances;

    /// @notice Native gas reserve (ETH/MATIC/BNB/XDC).
    uint256 public nativeBalance;

    // =========================================================
    // Events
    // =========================================================

    event TokenCredited(address indexed token, uint256 amount);
    event TokenReleased(address indexed token, address indexed to, uint256 amount);

    event NativeReimbursed(address indexed to, uint256 amount);

    event CoreUpdated(address indexed core);
    event TimelockUpdated(address indexed timelock);

    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // =========================================================
    // Initialization
    // =========================================================

    /// @param _timelock Timelock / governance controller.
    /// @param _core LolaCore contract address.
    constructor(address _timelock, address _core) {
        require(_timelock != address(0), "TIMELOCK_ZERO");
        require(_core != address(0), "CORE_ZERO");

        timelock = _timelock;
        core = _core;
    }

    // =========================================================
    // Core → Fee Credit
    // =========================================================

    /// @notice Credits ERC20 micro-fees into the vault (called by LolaCore).
    /// @param token ERC20 token being credited.
    /// @param amount Amount of token to credit.
    function credit(address token, uint256 amount)
        external
        onlyCore
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        require(token != address(0), "TOKEN_ZERO");
        require(amount > 0, "AMOUNT_ZERO");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        tokenBalances[token] += amount;

        emit TokenCredited(token, amount);
        return true;
    }

    /// @notice Returns the tracked balance for a given ERC20 token.
    function vaultBalance(address token) external view returns (uint256) {
        return tokenBalances[token];
    }

    // =========================================================
    // Core → Relayer Reimbursement (Native)
    // =========================================================

    /// @notice Executes a native-token reimbursement to a relayer.
    /// @dev Can only be called by LolaCore, which enforces all routing and limits.
    /// @param to Recipient (relayer) of the native reimbursement.
    /// @param amount Native amount to send (denominated in the chain's gas token).
    function reimburseNative(address payable to, uint256 amount)
        external
        onlyCore
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        require(to != address(0), "TO_ZERO");
        require(amount > 0, "AMOUNT_ZERO");
        require(nativeBalance >= amount, "INSUFFICIENT_NATIVE");

        nativeBalance -= amount;

        (bool ok,) = to.call{value: amount}("");
        require(ok, "NATIVE_FAIL");

        emit NativeReimbursed(to, amount);
        return true;
    }

    // =========================================================
    // Governance / Admin Controls
    // =========================================================

    /// @notice Governance-controlled ERC20 withdrawal (e.g. migration / emergency).
    /// @param token ERC20 token to withdraw.
    /// @param to Recipient address.
    /// @param amount Amount to withdraw.
    function adminReleaseToken(address token, address to, uint256 amount)
        external
        onlyTimelock
        nonReentrant
    {
        require(token != address(0), "TOKEN_ZERO");
        require(to != address(0), "TO_ZERO");
        require(amount > 0, "AMOUNT_ZERO");
        require(tokenBalances[token] >= amount, "INSUFFICIENT_BAL");

        tokenBalances[token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit TokenReleased(token, to, amount);
    }

    /// @notice Updates the LolaCore contract address.
    function setCore(address _core) external onlyTimelock {
        require(_core != address(0), "CORE_ZERO");
        core = _core;
        emit CoreUpdated(_core);
    }

    /// @notice Updates the timelock (governance) address.
    function setTimelock(address _timelock) external onlyTimelock {
        require(_timelock != address(0), "TIMELOCK_ZERO");
        timelock = _timelock;
        emit TimelockUpdated(_timelock);
    }

    /// @notice Pauses state-changing operations (credit / reimburse).
    function emergencyPause() external onlyTimelock {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpauses state-changing operations.
    function emergencyUnpause() external onlyTimelock {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // =========================================================
    // Native Handling
    // =========================================================

    /// @notice Receives native gas into the vault.
    /// @dev Restricted: only `core` or `timelock` may send native directly here.
    ///      This avoids arbitrary external ETH/XDC deposits that could confuse
    ///      accounting. Core can route native in as part of protocol flows; 
    ///      timelock can top up reserves manually.
    receive() external payable {
        require(
            msg.sender == core || msg.sender == timelock,
            "UNAUTHORIZED_NATIVE_SENDER"
        );
        nativeBalance += msg.value;
    }
}