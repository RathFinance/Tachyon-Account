/*
 ░█▀▄░█▀█░▀█▀░█░█░░░█▀▀░▀█▀░█▀█░█▀█░█▀█░█▀▀░█▀▀
 ░█▀▄░█▀█░░█░░█▀█░░░█▀▀░░█░░█░█░█▀█░█░█░█░░░█▀▀
 ░▀░▀░▀░▀░░▀░░▀░▀░░░▀░░░▀▀▀░▀░▀░▀░▀░▀░▀░▀▀▀░▀▀▀
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/ITachyonPaymaster.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title TachyonPaymaster
/// @author Aniket965, Rath.fi
/// @notice Unified Paymaster contract that manages multiple users and multiple tokens.
/// @dev Users can deposit multiple tokens, and the contract tracks balances per user per token.
contract TachyonPaymaster is ITachyonPaymaster, Ownable {
    /// @notice Address of the Rath Foundation authorized to submit bundle root hashes.
    address public immutable RathFoundation;

    /// @notice Duration of the cooling period required before an account can be closed.
    uint256 public constant COOLING_PERIOD = 7 days;

    /// @notice Struct to store user's account state.
    struct UserAccount {
        bool isClosureRequested;
        uint256 closureRequestTime;
        bool isClosed;
    }

    /// @notice Mapping from user address => UserAccount.
    mapping(address => UserAccount) public userAccounts;

    /// @notice Mapping from user address => token address => balance.
    mapping(address => mapping(address => uint256)) public balances;

    /// @notice Modifier to check if the user's account is open.
    /// @param user The address of the user.
    modifier onlyOpenAccount(address user) {
        if (userAccounts[user].isClosed) {
            revert AccountAlreadyClosed();
        }
        _;
    }

    /// @notice Modifier to check if the caller is RathFoundation.
    modifier onlyRathFoundation() {
        if (msg.sender != RathFoundation) {
            revert OnlyRathFoundationCanCharge();
        }
        _;
    }

    /// @notice Initializes the contract with the Rath Foundation address and owner.
    /// @param _rathFoundation Address of the Rath Foundation.
    /// @param _owner Address of the contract owner.
    constructor(address _rathFoundation, address _owner) {
        _initializeOwner(_owner);
        RathFoundation = _rathFoundation;
    }

    /// @inheritdoc ITachyonPaymaster
    function submitAccountClosureRequest() external override onlyOpenAccount(msg.sender) {
        UserAccount storage account = userAccounts[msg.sender];
        if (account.isClosureRequested) {
            revert ClosureRequestAlreadyOpen();
        }
        
        account.isClosureRequested = true;
        account.closureRequestTime = block.timestamp;
        
        emit AccountClosureRequested(msg.sender, block.timestamp);
    }

    /// @inheritdoc ITachyonPaymaster
    function cancelAccountClosureRequest() external override onlyOpenAccount(msg.sender) {
        UserAccount storage account = userAccounts[msg.sender];
        if (!account.isClosureRequested) {
            revert ClosureRequestRequired();
        }
        
        account.isClosureRequested = false;
        account.closureRequestTime = 0;
        
        emit AccountClosureCancelled(msg.sender);
    }

    /// @inheritdoc ITachyonPaymaster
    function closeAccount() external override onlyOpenAccount(msg.sender) {
        UserAccount storage account = userAccounts[msg.sender];
        
        if (!account.isClosureRequested) {
            revert ClosureRequestRequired();
        }
        if (block.timestamp < account.closureRequestTime + COOLING_PERIOD) {
            revert CoolingPeriodNotOver(block.timestamp, account.closureRequestTime + COOLING_PERIOD);
        }
        
        account.isClosed = true;
        account.isClosureRequested = false;
        
        emit AccountClosed(msg.sender);
    }

    /// @inheritdoc ITachyonPaymaster
    function withdraw(address token) external override {
        UserAccount storage account = userAccounts[msg.sender];
        
        if (!account.isClosed) {
            revert AccountNotClosed();
        }
        
        uint256 amount = balances[msg.sender][token];
        if (amount == 0) {
            revert InsufficientBalance();
        }
        
        balances[msg.sender][token] = 0;
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
        
        emit TokenWithdrawn(msg.sender, token, amount);
    }

    /// @inheritdoc ITachyonPaymaster
    function deposit(address token, uint256 amount) external override onlyOpenAccount(msg.sender) {
        if (token == address(0)) {
            revert InvalidToken();
        }
        if (amount == 0) {
            revert DepositAmountZero();
        }
        
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        balances[msg.sender][token] += amount;
        
        emit Deposit(msg.sender, token, amount);
    }

    /// @inheritdoc ITachyonPaymaster
    function version() external pure override returns (string memory) {
        return "0.0.1";
    }

    /// @inheritdoc ITachyonPaymaster
    function chargeAccount(
        address user,
        address token,
        uint256 amount,
        bytes32 bundleRootHash
    ) external override onlyRathFoundation onlyOpenAccount(user) {
        if (balances[user][token] < amount) {
            revert InsufficientBalance();
        }
        
        balances[user][token] -= amount;
        SafeTransferLib.safeTransfer(token, RathFoundation, amount);
        
        emit AccountCharged(user, token, amount, bundleRootHash);
    }

    /// @inheritdoc ITachyonPaymaster
    function rescueAccount(
        address user,
        address token,
        uint256 amount
    ) external override onlyRathFoundation {
        // For rescue, we check if the user account is closed
        // or we allow rescuing any accidentally sent ETH
        if (!userAccounts[user].isClosed && token != address(0)) {
            revert AccountNotClosed();
        }
        
        if (token == address(0)) {
            // Rescue ETH
            SafeTransferLib.safeTransferETH(RathFoundation, amount);
        } else {
            SafeTransferLib.safeTransfer(token, RathFoundation, amount);
        }
        
        emit AccountRescued(user, token, amount);
    }

    /// @inheritdoc ITachyonPaymaster
    function balanceOf(address user, address token) external view override returns (uint256) {
        return balances[user][token];
    }

    /// @inheritdoc ITachyonPaymaster
    function getAccountStatus(
        address user
    ) external view override returns (
        bool isClosed,
        bool isClosureRequested,
        uint256 closureRequestTime
    ) {
        UserAccount storage account = userAccounts[user];
        return (account.isClosed, account.isClosureRequested, account.closureRequestTime);
    }

    /// @notice Allows the contract to receive ETH.
    receive() external payable {}
}
