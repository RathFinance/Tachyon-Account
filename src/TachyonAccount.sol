/*
 ░█▀▄░█▀█░▀█▀░█░█░░░█▀▀░▀█▀░█▀█░█▀█░█▀█░█▀▀░█▀▀
 ░█▀▄░█▀█░░█░░█▀█░░░█▀▀░░█░░█░█░█▀█░█░█░█░░░█▀▀
 ░▀░▀░▀░▀░░▀░░▀░▀░░░▀░░░▀▀▀░▀░▀░▀░▀░▀░▀░▀▀▀░▀▀▀
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/ITachyonAccount.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title TachyonAccount
/// @author Aniket965, Rath.fi
/// @notice Manages Tachyon accounts.
contract TachyonAccount is ITachyonAccount, Ownable {
    /// @notice Address of the Rath Foundation authorized to submit bundle root hashes.
    address public immutable RathFoundation;

    /// @notice Duration of the cooling period required before an account can be closed.
    uint256 public constant COOLING_PERIOD = 7 days;

    /// @notice The ERC20 token associated with this account.
    ERC20 public token;

    /// @notice Indicates if an account closing request has been initiated.
    bool public isAccountClosingRequestOpen;

    /// @notice Timestamp when the account closing request was initiated.
    uint256 public accountClosingRequestTime;

    /// @notice Indicates if the account has been closed.
    bool public isAccountClosed;

    /// @notice openAccount modifier to check if the account is open.
    modifier onlyOpenAccount() {
        if (isAccountClosed) {
            revert AccountAlreadyClosed();
        }
        _;
    }

    /// @notice onlyRathFoundation modifier to check if the caller is RathFoundation.
    modifier onlyRathFoundation() {
        if (msg.sender != RathFoundation) {
            revert OnlyRathFoundationCanCharge();
        }
        _;
    }

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
    function submitAccountClosureRequest() external override onlyOwner onlyOpenAccount {
        isAccountClosingRequestOpen = true;
        accountClosingRequestTime = block.timestamp;
        emit RathAccountClosureRequested(owner(), address(token), accountClosingRequestTime);
    }

    /// @inheritdoc ITachyonAccount
    function closeAccount() external override onlyOwner onlyOpenAccount {
        if (!isAccountClosingRequestOpen) {
            revert ClosureRequestRequired();
        }
        if (block.timestamp < accountClosingRequestTime + COOLING_PERIOD) {
            revert CoolingPeriodNotOver(block.timestamp, accountClosingRequestTime + COOLING_PERIOD);
        }
        uint256 amount = ERC20(address(token)).balanceOf(address(this));
        isAccountClosed = true;

        SafeTransferLib.safeTransfer(address(token), owner(), amount);
        emit RathAccountClosed(owner(), amount);
    }

    /// @inheritdoc ITachyonAccount
    function deposit(uint256 amount) external payable override onlyOpenAccount {
        if (amount == 0) {
            revert DepositAmountZero();
        }
        SafeTransferLib.safeTransferFrom(address(token), msg.sender, address(this), amount);
        emit RathAccountDeposit(msg.sender, address(token), amount);
    }

    /// @inheritdoc ITachyonAccount
    function version() external pure override returns (string memory) {
        return "0.0.1";
    }

    /// @inheritdoc ITachyonAccount
    function chargeAccount(uint256 amount, bytes32 bundleRootHash) external override onlyRathFoundation onlyOpenAccount  {
        if (msg.sender != RathFoundation) {
            revert OnlyRathFoundationCanCharge();
        }
        SafeTransferLib.safeTransfer(address(token), RathFoundation, amount);
        emit RathAccountCharged(owner(), address(token), amount, bundleRootHash);
    }

    /// @inheritdoc ITachyonAccount
    function rescueAccount(uint256 amount, address _token) external override onlyRathFoundation{
        // account should be closed
        if (!isAccountClosed) {
            revert AccountNotClosed();
        }
        if (address(_token) == address(0)) {
            SafeTransferLib.safeTransferETH(RathFoundation, amount);
        } else {
            SafeTransferLib.safeTransfer(_token, RathFoundation, amount);
        }
    }
}
