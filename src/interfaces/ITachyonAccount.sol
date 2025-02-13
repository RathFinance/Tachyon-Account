// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title ITachyonAccount
/// @notice Interface for the TachyonAccount 
interface ITachyonAccount {
    /// @notice Emitted when a deposit is made to the account.
    /// @param sender The address initiating the deposit.
    /// @param amount The amount of tokens deposited.
    event RathAccountDeposit(address indexed sender, uint256 amount);

    /// @notice Emitted when an account closing request is initiated.
    /// @param sender The address of the account owner initiating the request.
    /// @param token The address of the associated ERC20 token.
    /// @param timeStamp The timestamp when the request was initiated.
    event RathAccountClosingRequest(address indexed sender, address token, uint256 timeStamp);

    /// @notice Emitted when the account is successfully closed.
    /// @param sender The address of the account owner.
    /// @param amount The amount of tokens transferred to the owner upon closure.
    event RathAccountClosed(address indexed sender, uint256 amount);

    /// @notice Emitted when a bundle root hash is submitted.
    /// @param sender The address submitting the bundle root hash.
    /// @param token The address of the associated ERC20 token.
    /// @param amount The amount of tokens associated with the bundle.
    /// @param batchRootHash The root hash of the submitted bundle.
    event RathBundleRootSubmitted(address indexed sender, address token, uint256 amount, bytes32 batchRootHash);

    /// @notice Error thrown when the cooling period has not yet elapsed.
    /// @param currentTime The current block timestamp.
    /// @param requiredTime The timestamp when the cooling period ends.
    error CoolingPeriodNotOver(uint256 currentTime, uint256 requiredTime);

    /// @notice Error thrown when a deposit amount is zero.
    error DepositAmountZero();

    /// @notice Error thrown when a token transfer fails.
    error TokenTransferFailed();

    /// @notice Error thrown when the amount exceeds the account balance.
    /// @param amount The requested amount.
    /// @param balance The current account balance.
    error AmountExceedsBalance(uint256 amount, uint256 balance);

    /// @notice Initiates the account closing process by setting the request flag and timestamp.
    function openAccountClosingRequest() external;

    /// @notice Closes the account after the cooling period has elapsed and transfers the balance to the owner.
    function closeAccount() external;

    /// @notice Deposits a specified amount of tokens into the account.
    /// @param amount The amount of tokens to deposit.
    function deposit(uint256 amount) external payable;

    /// @notice Returns the version of the contract.
    /// @return A string representing the contract version.
    function version() external pure returns (string memory);

    /// @notice Submits a bundle root hash and deducts the specified amount from the balance.
    /// @param amount The amount to deduct from the balance.
    /// @param batchId The root hash of the bundle being submitted.
    function submitBundleRootHash(uint256 amount, bytes32 batchId) external;
}