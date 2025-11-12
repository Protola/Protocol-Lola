// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @notice Pluggable DEX adapter interface (must return native to this vault).
interface IDexAdapter {
    function swapToNative(
        address tokenIn,
        uint256 amountIn,
        uint256 minNativeOut,
        bytes calldata route
    ) external returns (uint256 out);
}

/// @title LolaVault1
/// @notice Multi-asset liquidity vault for the Lola Protocol.
/// @dev Holds diversified ERC20 reserves and can execute on-network swaps to native
///      via a pluggable DEX adapter. Controlled by timelock governance. This vault
///      is separate from the micro-fee / reimbursement vault (LolaVault2).
contract LolaVault1 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================
    // Governance
    // =========================================================

    /// @notice Timelock / governance controller.
    address public timelock;

    /// @notice Pluggable DEX adapter used for token->native swaps.
    IDexAdapter public dexAdapter;

    /// @notice Global pause flag for state-changing operations.
    bool public paused;

    modifier onlyTimelock() {
        require(msg.sender == timelock, "NOT_TIMELOCK");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    // =========================================================
    // State
    // =========================================================

    /// @notice Per-token ERC20 balances tracked by the vault.
    mapping(address => uint256) private tokenBalances;

    /// @notice Native gas balance tracked internally (ETH/MATIC/BNB/XDC).
    uint256 public nativeBalance;

    // =========================================================
    // Events
    // =========================================================

    event TokenCredited(address indexed token, uint256 amount);
    event TokenReleased(address indexed token, address indexed to, uint256 amount);

    event NativeReleased(address indexed to, uint256 amount);
    event SwapExecuted(address indexed token, uint256 amountIn, uint256 nativeOut);

    event DexAdapterUpdated(address indexed adapter);
    event TimelockUpdated(address indexed timelock);

    event EmergencyPaused(address indexed by);
    event EmergencyUnpaused(address indexed by);

    // =========================================================
    // Initialization
    // =========================================================

    /// @param _timelock Timelock / governance controller.
    /// @param _dexAdapter Initial DEX adapter used for on-network swaps.
    constructor(address _timelock, address _dexAdapter) {
        require(_timelock != address(0), "TIMELOCK_ZERO");
        require(_dexAdapter != address(0), "ADAPTER_ZERO");

        timelock = _timelock;
        dexAdapter = IDexAdapter(_dexAdapter);
    }

    // =========================================================
    // Liquidity / Vault Operations
    // =========================================================

    /// @notice Credits ERC20 tokens into the vault.
    /// @dev Open deposit function. Caller must have approved `amount` beforehand.
    ///      Intended for protocol treasury, governance, or integrations that send
    ///      assets into Vault1 for liquidity management.
    /// @param token ERC20 token to deposit.
    /// @param amount Amount of token to deposit.
    function credit(address token, uint256 amount)
        external
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

    /// @notice Governance-controlled withdrawal of ERC20 (e.g., migration / treasury ops).
    /// @param token ERC20 token to withdraw.
    /// @param to Recipient address.
    /// @param amount Amount to withdraw.
    function releaseTo(address token, address to, uint256 amount)
        external
        onlyTimelock
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        require(token != address(0), "TOKEN_ZERO");
        require(to != address(0), "TO_ZERO");
        require(amount > 0, "AMOUNT_ZERO");
        require(tokenBalances[token] >= amount, "INSUFFICIENT_BAL");

        tokenBalances[token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit TokenReleased(token, to, amount);
        return true;
    }

    /// @notice Governance-controlled withdrawal of native gas (for reimbursements, ops, etc.).
    /// @param to Recipient address.
    /// @param amount Native amount to withdraw.
    function releaseNative(address payable to, uint256 amount)
        external
        onlyTimelock
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

        emit NativeReleased(to, amount);
        return true;
    }

    // =========================================================
    // Swap Logic (Token -> Native)
    // =========================================================

    /// @notice Swaps ERC20 token into native gas via the configured DEX adapter.
    /// @dev Only callable by timelock. Uses a just-in-time allowance bump pattern,
    ///      then reduces allowance back afterward to avoid long-lived approvals.
    ///
    /// @param token ERC20 token to sell.
    /// @param amountIn Amount of token to swap.
    /// @param minOut Minimum acceptable native amount (slippage guard).
    /// @param deadline Expiration timestamp for this quote.
    /// @param route Encoded route data for the DEX adapter.
    ///
    /// @return nativeOut Actual native amount received.
    function swapToNative(
        address token,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        bytes calldata route
    )
        external
        onlyTimelock
        whenNotPaused
        nonReentrant
        returns (uint256 nativeOut)
    {
        require(block.timestamp <= deadline, "QUOTE_EXPIRED");
        require(token != address(0), "TOKEN_ZERO");
        require(amountIn > 0, "AMOUNT_ZERO");
        require(tokenBalances[token] >= amountIn, "INSUFFICIENT_TOKEN");

        tokenBalances[token] -= amountIn;

        IERC20 t = IERC20(token);

        // 1) Bump allowance just-in-time.
        uint256 currentAllow = t.allowance(address(this), address(dexAdapter));
        if (currentAllow < amountIn) {
            t.safeIncreaseAllowance(address(dexAdapter), amountIn - currentAllow);
        }

        // 2) Measure native balance delta for correctness.
        uint256 beforeBal = address(this).balance;

        // Adapter returns native to this vault in the same transaction.
        dexAdapter.swapToNative(token, amountIn, minOut, route);

        uint256 afterBal = address(this).balance;
        nativeOut = afterBal - beforeBal;

        // Enforce minOut locally (do not rely on adapter return values).
        require(nativeOut >= minOut, "SLIPPAGE_EXCEEDED");

        // 3) Reduce allowance back to previous level (or lower if non-standard token).
        uint256 postAllow = t.allowance(address(this), address(dexAdapter));
        if (postAllow >= amountIn) {
            t.safeDecreaseAllowance(address(dexAdapter), amountIn);
        } else {
            // Fallback: close out remaining allowance to avoid lingering exposure.
            t.safeDecreaseAllowance(address(dexAdapter), postAllow);
        }

        nativeBalance += nativeOut;

        emit SwapExecuted(token, amountIn, nativeOut);
    }

    // =========================================================
    // Views
    // =========================================================

    /// @notice Returns the tracked balance for a given ERC20 token.
    function vaultBalance(address token) external view returns (uint256) {
        return tokenBalances[token];
    }

    // =========================================================
    // Governance Controls
    // =========================================================

    /// @notice Updates the DEX adapter used for swaps.
    function setDexAdapter(address adapter) external onlyTimelock {
        require(adapter != address(0), "ADAPTER_ZERO");
        dexAdapter = IDexAdapter(adapter);
        emit DexAdapterUpdated(adapter);
    }

    /// @notice Updates the timelock controller.
    function setTimelock(address _timelock) external onlyTimelock {
        require(_timelock != address(0), "TIMELOCK_ZERO");
        timelock = _timelock;
        emit TimelockUpdated(_timelock);
    }

    /// @notice Pauses state-changing operations.
    function emergencyPause() external onlyTimelock {
        paused = true;
        emit EmergencyPaused(msg.sender);
    }

    /// @notice Unpauses state-changing operations.
    function emergencyUnpause() external onlyTimelock {
        paused = false;
        emit EmergencyUnpaused(msg.sender);
    }

    // =========================================================
    // Native Handling
    // =========================================================

    /// @notice Receives native gas into the vault (e.g. from swaps or top-ups).
    /// @dev Intentional open receive: governance can later move or track these funds
    ///      via `releaseNative`. If you want to restrict this further, you can gate
    ///      it by sender addresses as in Vault2.
    receive() external payable {
        nativeBalance += msg.value;
    }
}