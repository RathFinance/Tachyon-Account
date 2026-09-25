/*
 ░█▀▄░█▀█░▀█▀░█░█░░░█▀▀░▀█▀░█▀█░█▀█░█▀█░█▀▀░█▀▀
 ░█▀▄░█▀█░░█░░█▀█░░░█▀▀░░█░░█░█░█▀█░█░█░█░░░█▀▀
 ░▀░▀░▀░▀░░▀░░▀░▀░░░▀░░░▀▀▀░▀░▀░▀░▀░▀░▀░▀▀▀░▀▀▀
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IRathPaymaster} from "./interfaces/IRathPaymaster.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";

/// @title RathPaymaster
/// @author Team@rath.fi
/// @notice Unified Paymaster contract that manages multiple users and multiple tokens.
/// @dev Users can deposit multiple tokens, and the contract tracks balances per user per token.
///      This contract is the UUPS implementation behind an ERC-1967 proxy; all state lives in
///      the proxy. Storage is append-only: never reorder, retype, or remove an existing variable
///      in an upgrade, only add new ones after the last one.
contract RathPaymaster is IRathPaymaster, Initializable, UUPSUpgradeable, Ownable {
    /// @notice Address of the Rath Foundation authorized to submit bundle root hashes.
    /// @dev Storage rather than immutable so it survives upgrades without being re-supplied.
    address public rathFoundation;

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
        _onlyOpenAccount(user);
        _;
    }

    /// @notice Modifier to check if the caller is RathFoundation.
    modifier onlyRathFoundation() {
        _onlyRathFoundation();
        _;
    }

    /// @notice Reverts unless the given user's account is still open.
    /// @param user The address of the user.
    function _onlyOpenAccount(address user) private view {
        if (userAccounts[user].isClosed) {
            revert AccountAlreadyClosed();
        }
    }

    /// @notice Reverts unless the caller is RathFoundation.
    function _onlyRathFoundation() private view {
        if (msg.sender != rathFoundation) {
            revert OnlyRathFoundationCanCharge();
        }
    }

    /// @notice Locks the implementation so it can only ever be used through a proxy.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy with the Rath Foundation address and owner.
    /// @dev Called once, in the proxy's constructor, so it cannot be front-run.
    /// @param _rathFoundation Address of the Rath Foundation.
    /// @param _owner Address of the contract owner.
    function initialize(address _rathFoundation, address _owner) external initializer {
        if (_rathFoundation == address(0) || _owner == address(0)) {
            revert InvalidUser();
        }

        _initializeOwner(_owner);
        rathFoundation = _rathFoundation;
    }

    /// @notice Restricts proxy upgrades to the owner.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Makes `_initializeOwner` revert if the owner has already been set.
    /// @dev Defense in depth against the ownership being re-seeded by a later initializer.
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IRathPaymaster
    function submitAccountClosureRequest() external override onlyOpenAccount(msg.sender) {
        UserAccount storage account = userAccounts[msg.sender];
        if (account.isClosureRequested) {
            revert ClosureRequestAlreadyOpen();
        }

        account.isClosureRequested = true;
        account.closureRequestTime = block.timestamp;

        emit AccountClosureRequested(msg.sender, block.timestamp);
    }

    /// @inheritdoc IRathPaymaster
    function cancelAccountClosureRequest() external override onlyOpenAccount(msg.sender) {
        UserAccount storage account = userAccounts[msg.sender];
        if (!account.isClosureRequested) {
            revert ClosureRequestRequired();
        }

        account.isClosureRequested = false;
        account.closureRequestTime = 0;

        emit AccountClosureCancelled(msg.sender);
    }

    /// @inheritdoc IRathPaymaster
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

    /// @inheritdoc IRathPaymaster
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

    /// @notice Validates the common parameters shared by every deposit entrypoint.
    /// @param user The address whose balance will be credited.
    /// @param token The address of the ERC20 token to deposit.
    /// @param amount The amount of tokens to deposit.
    function _validateDeposit(address user, address token, uint256 amount) private pure {
        if (user == address(0)) {
            revert InvalidUser();
        }
        if (token == address(0)) {
            revert InvalidToken();
        }
        if (amount == 0) {
            revert DepositAmountZero();
        }
    }

    /// @notice Pulls `amount` of `token` from the caller and credits what was actually received to `user`.
    /// @dev Measures the balance delta so fee-on-transfer tokens credit only what the paymaster received.
    /// @param user The address whose balance will be credited.
    /// @param token The address of the ERC20 token to deposit.
    /// @param amount The amount of tokens to pull from the caller.
    function _deposit(address user, address token, uint256 amount) private {
        uint256 balanceBefore = ERC20(token).balanceOf(address(this));
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 received = ERC20(token).balanceOf(address(this)) - balanceBefore;

        balances[user][token] += received;

        emit Deposit(msg.sender, user, token, received);
    }

    /// @notice Consumes an EIP-2612 permit signed by the caller, approving this contract for `amount`.
    /// @dev A permit that has already been consumed (e.g. front-run) is tolerated as long as the
    ///      resulting allowance still covers `amount`, so the deposit itself cannot be griefed.
    /// @param token The address of the ERC20 token being permitted.
    /// @param amount The allowance the permit grants to this contract.
    /// @param deadline The permit expiry timestamp.
    /// @param v The signature `v` component.
    /// @param r The signature `r` component.
    /// @param s The signature `s` component.
    function _permit(address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) private {
        try ERC20(token).permit(msg.sender, address(this), amount, deadline, v, r, s) {}
        catch {
            if (ERC20(token).allowance(msg.sender, address(this)) < amount) {
                revert PermitFailed();
            }
        }
    }

    /// @inheritdoc IRathPaymaster
    function deposit(address token, uint256 amount) external override onlyOpenAccount(msg.sender) {
        _validateDeposit(msg.sender, token, amount);
        _deposit(msg.sender, token, amount);
    }

    /// @inheritdoc IRathPaymaster
    function depositWithPermit(address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
        onlyOpenAccount(msg.sender)
    {
        _validateDeposit(msg.sender, token, amount);
        _permit(token, amount, deadline, v, r, s);
        _deposit(msg.sender, token, amount);
    }

    /// @inheritdoc IRathPaymaster
    function depositFor(address user, address token, uint256 amount) external override onlyOpenAccount(user) {
        _validateDeposit(user, token, amount);
        _deposit(user, token, amount);
    }

    /// @inheritdoc IRathPaymaster
    function depositForWithPermit(
        address user,
        address token,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override onlyOpenAccount(user) {
        _validateDeposit(user, token, amount);
        _permit(token, amount, deadline, v, r, s);
        _deposit(user, token, amount);
    }

    /// @inheritdoc IRathPaymaster
    function version() external pure override returns (string memory) {
        return "0.0.2";
    }

    /// @inheritdoc IRathPaymaster
    function chargeAccount(address user, address token, uint256 amount, bytes32 bundleRootHash)
        external
        override
        onlyRathFoundation
        onlyOpenAccount(user)
    {
        if (balances[user][token] < amount) {
            revert InsufficientBalance();
        }

        balances[user][token] -= amount;
        SafeTransferLib.safeTransfer(token, rathFoundation, amount);

        emit AccountCharged(user, token, amount, bundleRootHash);
    }

    /// @inheritdoc IRathPaymaster
    function rescueAccount(address user, address token, uint256 amount) external override onlyRathFoundation {
        // For rescue, we check if the user account is closed
        // or we allow rescuing any accidentally sent ETH
        if (!userAccounts[user].isClosed && token != address(0)) {
            revert AccountNotClosed();
        }

        if (token == address(0)) {
            // Rescue ETH
            SafeTransferLib.safeTransferETH(rathFoundation, amount);
        } else {
            // Rescuing an ERC20 must debit the user's tracked balance so the
            // rescued amount cannot later be re-withdrawn by the user, and so
            // it can never exceed what that user actually deposited.
            if (balances[user][token] < amount) {
                revert InsufficientBalance();
            }
            balances[user][token] -= amount;
            SafeTransferLib.safeTransfer(token, rathFoundation, amount);
        }

        emit AccountRescued(user, token, amount);
    }

    /// @inheritdoc IRathPaymaster
    function balanceOf(address user, address token) external view override returns (uint256) {
        return balances[user][token];
    }

    /// @inheritdoc IRathPaymaster
    function getAccountStatus(address user)
        external
        view
        override
        returns (bool isClosed, bool isClosureRequested, uint256 closureRequestTime)
    {
        UserAccount storage account = userAccounts[user];
        return (account.isClosed, account.isClosureRequested, account.closureRequestTime);
    }

    /// @notice Allows the contract to receive ETH.
    receive() external payable {}
}
