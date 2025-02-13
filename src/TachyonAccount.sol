// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/ITachyonAccount.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title TachyonAccount
/// @author Aniket965, RathFoundation
/// @notice Manages Tachyon accounts.
contract TachyonAccount is ITachyonAccount, Ownable {

    /// @notice Address of the Rath Foundation authorized to submit bundle root hashes.
    address public immutable RathFoundation;

    /// @notice Duration of the cooling period required before an account can be closed.
    uint256 public constant COOLING_PERIOD = 7 days;

    /// @notice Current balance of the account in tokens.
    uint256 public balance;

    /// @notice The ERC20 token associated with this account.
    ERC20 public token;

    /// @notice Indicates if an account closing request has been initiated.
    bool public isAccountClosingRequestOpen;

    /// @notice Timestamp when the account closing request was initiated.
    uint256 public accountClosingRequestTime;

    /// @notice Indicates if the account has been closed.
    bool public isAccountClosed;


    /// @notice Initializes the contract with the Rath Foundation address, owner, and associated token.
    /// @param _rathFoundation Address of the Rath Foundation.
    /// @param _owner Address of the contract owner.
    /// @param _token Address of the ERC20 token associated with this account.
    constructor(address _rathFoundation, address _owner, address _token) {
        _initializeOwner(_owner);
        RathFoundation = _rathFoundation;
        token = ERC20(_token);
    }

    /// @inheritdoc ITachyonAccount
    function openAccountClosingRequest() external override onlyOwner {
        isAccountClosingRequestOpen = true;
        accountClosingRequestTime = block.timestamp;
        emit RathAccountClosingRequest(owner(), address(token), accountClosingRequestTime);
    }

    /// @inheritdoc ITachyonAccount
    function closeAccount() external override onlyOwner {
        if (!isAccountClosingRequestOpen) {
            revert Unauthorized();
        }
        if (block.timestamp < accountClosingRequestTime + COOLING_PERIOD) {
            revert CoolingPeriodNotOver(block.timestamp, accountClosingRequestTime + COOLING_PERIOD);
        }
        uint256 amount = balance;
        
        balance = 0;
        isAccountClosed = true;
        
        SafeTransferLib.safeTransfer(address(token),owner(), amount);
        emit RathAccountClosed(owner(), amount);
    }

    /// @inheritdoc ITachyonAccount
    function deposit(uint256 amount) external payable override {
        if (amount == 0) {
            revert DepositAmountZero();
        }
        SafeTransferLib.safeTransferFrom(address(token), msg.sender, address(this), amount);
        balance += amount;
        emit RathAccountDeposit(msg.sender, amount);
    }

    /// @inheritdoc ITachyonAccount
    function version() external pure override returns (string memory) {
        return "0.0.1";
    }

    /// @inheritdoc ITachyonAccount
    function submitBundleRootHash(uint256 amount, bytes32 bundleRootHash) external override {
        if (msg.sender != RathFoundation) {
            revert Unauthorized();
        }
        if (amount > balance) {
            revert AmountExceedsBalance(amount, balance);
        }
        balance -= amount;
        SafeTransferLib.safeTransfer(address(token),RathFoundation, amount);
        emit RathBundleRootSubmitted(owner(), address(token), amount, bundleRootHash);
    }
}