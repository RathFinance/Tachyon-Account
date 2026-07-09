// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title ITachyonPaymaster
/// @notice Interface for the unified TachyonPaymaster that manages multiple users and tokens
interface ITachyonPaymaster {
    /// @notice Emitted when a deposit is made to the paymaster.
    /// @param user The address of the user depositing.
    /// @param token The address of the ERC20 token deposited.
    /// @param amount The amount of tokens deposited.
    event Deposit(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when a payer deposits into another user's paymaster balance.
    /// @param payer The address funding the deposit.
    /// @param user The address whose balance is credited.
    /// @param token The address of the ERC20 token deposited.
    /// @param amount The amount of tokens deposited.
    event DepositFor(address indexed payer, address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when an account closing request is initiated.
    /// @param user The address of the user initiating the request.
    /// @param timestamp The timestamp when the request was initiated.
    event AccountClosureRequested(address indexed user, uint256 timestamp);

    /// @notice Emitted when an account closing request is cancelled.
    /// @param user The address of the user cancelling the request.
    event AccountClosureCancelled(address indexed user);

    /// @notice Emitted when a user's account is successfully closed.
    /// @param user The address of the user.
    event AccountClosed(address indexed user);

    /// @notice Emitted when a token is withdrawn during account closure.
    /// @param user The address of the user.
    /// @param token The address of the ERC20 token.
    /// @param amount The amount of tokens transferred to the user.
    event TokenWithdrawn(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when a user's account is charged with bundle root hash.
    /// @param user The address of the user being charged.
    /// @param token The address of the ERC20 token.
    /// @param amount The amount of tokens charged.
    /// @param batchRootHash The root hash of the submitted bundle.
    event AccountCharged(address indexed user, address indexed token, uint256 amount, bytes32 batchRootHash);

    /// @notice Emitted when tokens are rescued from a closed account.
    /// @param user The address of the user whose tokens were rescued.
    /// @param token The address of the rescued token (address(0) for ETH).
    /// @param amount The amount rescued.
    event AccountRescued(address indexed user, address indexed token, uint256 amount);

    /// @notice Error thrown when the cooling period has not yet elapsed.
    /// @param currentTime The current block timestamp.
    /// @param requiredTime The timestamp when the cooling period ends.
    error CoolingPeriodNotOver(uint256 currentTime, uint256 requiredTime);

    /// @notice Error thrown when a deposit amount is zero.
    error DepositAmountZero();

    /// @notice Error thrown when the caller is not authorized to charge the account.
    error OnlyRathFoundationCanCharge();

    /// @notice Error thrown when the token account is already closed.
    error AccountAlreadyClosed();

    /// @notice Error thrown when the token account is not closed.
    error AccountNotClosed();

    /// @notice Error thrown when the account closure request is not initiated.
    error ClosureRequestRequired();

    /// @notice Error thrown when closure request is already open.
    error ClosureRequestAlreadyOpen();

    /// @notice Error thrown when there is insufficient balance.
    error InsufficientBalance();

    /// @notice Error thrown when token address is invalid.
    error InvalidToken();

    /// @notice Error thrown when user address is invalid.
    error InvalidUser();

    /// @notice Initiates the account closing process for the user.
    function submitAccountClosureRequest() external;

    /// @notice Cancels an account closing request.
    function cancelAccountClosureRequest() external;

    /// @notice Closes the account after the cooling period has elapsed.
    function closeAccount() external;

    /// @notice Withdraws a specified token after the account has been closed.
    /// @param token The address of the ERC20 token to withdraw.
    function withdraw(address token) external;

    /// @notice Deposits a specified amount of tokens into the user's account.
    /// @param token The address of the ERC20 token to deposit.
    /// @param amount The amount of tokens to deposit.
    function deposit(address token, uint256 amount) external;

    /// @notice Deposits a specified amount of tokens into another user's account.
    /// @param user The address whose balance will be credited.
    /// @param token The address of the ERC20 token to deposit.
    /// @param amount The amount of tokens to deposit.
    function depositFor(address user, address token, uint256 amount) external;

    /// @notice Returns the version of the contract.
    /// @return A string representing the contract version.
    function version() external pure returns (string memory);

    /// @notice Charges a user's account with the specified amount and bundle root hash.
    /// @param user The address of the user to charge.
    /// @param token The address of the ERC20 token.
    /// @param amount The amount to deduct from the balance.
    /// @param bundleRootHash The root hash of the bundle being submitted.
    function chargeAccount(address user, address token, uint256 amount, bytes32 bundleRootHash) external;

    /// @notice Rescues tokens from a closed account.
    /// @param user The address of the user whose tokens to rescue.
    /// @param token The address of the token to rescue (address(0) for ETH).
    /// @param amount The amount to rescue.
    function rescueAccount(address user, address token, uint256 amount) external;

    /// @notice Returns the balance of a user for a specific token.
    /// @param user The address of the user.
    /// @param token The address of the ERC20 token.
    /// @return The balance amount.
    function balanceOf(address user, address token) external view returns (uint256);

    /// @notice Returns the account status for a user.
    /// @param user The address of the user.
    /// @return isClosed Whether the account is closed.
    /// @return isClosureRequested Whether a closure request is pending.
    /// @return closureRequestTime The timestamp of the closure request.
    function getAccountStatus(address user)
        external
        view
        returns (bool isClosed, bool isClosureRequested, uint256 closureRequestTime);
}
