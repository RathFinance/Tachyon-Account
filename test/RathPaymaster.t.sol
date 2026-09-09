// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {IRathPaymaster} from "../src/interfaces/IRathPaymaster.sol";
import {RathPaymaster} from "../src/RathPaymaster.sol";

contract MockERC20 is ERC20 {
    function name() public pure override returns (string memory) {
        return "Mock USD";
    }

    function symbol() public pure override returns (string memory) {
        return "mUSD";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Token that takes a fixed basis-point fee on every transfer, delivering
///      less than requested. Used to exercise the paymaster's accounting under
///      non-standard ERC20s.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public constant FEE_BPS = 1000; // 10%

    function name() public pure override returns (string memory) {
        return "Fee Token";
    }

    function symbol() public pure override returns (string memory) {
        return "FEE";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        // Burn the fee from the recipient after transfer so it nets amount - fee.
        // (Skip mints, and skip our own burn to avoid recursion.)
        if (from != address(0) && to != address(0)) {
            uint256 fee = (amount * FEE_BPS) / 10_000;
            if (fee != 0) _burn(to, fee);
        }
    }
}

/// @dev Token that re-enters the paymaster's `withdraw` during its own transfer,
///      to prove the withdraw path follows Checks-Effects-Interactions.
contract ReentrantERC20 is ERC20 {
    RathPaymaster public paymaster;
    bool private attacking;

    function name() public pure override returns (string memory) {
        return "Reentrant";
    }

    function symbol() public pure override returns (string memory) {
        return "RE";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaymaster(RathPaymaster _paymaster) external {
        paymaster = _paymaster;
    }

    function _afterTokenTransfer(address from, address, uint256) internal override {
        // When the paymaster pays out during withdraw, try to re-enter withdraw.
        if (attacking && from == address(paymaster)) {
            attacking = false;
            paymaster.withdraw(address(this));
        }
    }

    function arm() external {
        attacking = true;
    }
}

contract RathPaymasterTest is Test {
    address private constant RATH_FOUNDATION = address(0x1001);
    address private constant OWNER = address(0x1002);
    address private constant PAYER = address(0x1003);
    address private constant USER = address(0x1004);
    address private constant OTHER = address(0x1005);

    RathPaymaster private paymaster;
    MockERC20 private token;

    function setUp() public {
        paymaster = new RathPaymaster(RATH_FOUNDATION, OWNER);
        token = new MockERC20();

        token.mint(PAYER, 1_000e6);
        token.mint(USER, 1_000e6);
        token.mint(OTHER, 1_000e6);

        vm.prank(PAYER);
        token.approve(address(paymaster), type(uint256).max);

        vm.prank(USER);
        token.approve(address(paymaster), type(uint256).max);

        vm.prank(OTHER);
        token.approve(address(paymaster), type(uint256).max);
    }

    function testConstructorSetsRolesAndConstants() public view {
        assertEq(paymaster.RathFoundation(), RATH_FOUNDATION);
        assertEq(paymaster.owner(), OWNER);
        assertEq(paymaster.COOLING_PERIOD(), 7 days);
        assertEq(paymaster.version(), "0.0.1");
    }

    function testDepositCreditsCallerAndEmitsDeposit() public {
        uint256 amount = 100e6;

        vm.expectEmit(true, true, false, true, address(paymaster));
        emit IRathPaymaster.Deposit(USER, address(token), amount);

        vm.prank(USER);
        paymaster.deposit(address(token), amount);

        assertEq(paymaster.balanceOf(USER, address(token)), amount);
        assertEq(paymaster.balanceOf(PAYER, address(token)), 0);
        assertEq(token.balanceOf(address(paymaster)), amount);
        assertEq(token.balanceOf(USER), 900e6);
    }

    function testDepositAccumulatesAcrossCalls() public {
        vm.startPrank(USER);
        paymaster.deposit(address(token), 100e6);
        paymaster.deposit(address(token), 50e6);
        vm.stopPrank();

        assertEq(paymaster.balanceOf(USER, address(token)), 150e6);
        assertEq(token.balanceOf(address(paymaster)), 150e6);
    }

    function testDepositRevertsForZeroToken() public {
        vm.expectRevert(IRathPaymaster.InvalidToken.selector);
        vm.prank(USER);
        paymaster.deposit(address(0), 1);
    }

    function testDepositRevertsForZeroAmount() public {
        vm.expectRevert(IRathPaymaster.DepositAmountZero.selector);
        vm.prank(USER);
        paymaster.deposit(address(token), 0);
    }

    function testDepositRevertsWhenAccountClosed() public {
        _close(USER);

        vm.expectRevert(IRathPaymaster.AccountAlreadyClosed.selector);
        vm.prank(USER);
        paymaster.deposit(address(token), 1);
    }

    function testDepositRevertsWithoutApproval() public {
        address noApprove = address(0x2001);
        token.mint(noApprove, 10e6);

        vm.expectRevert(); // solady SafeTransferLib TransferFromFailed
        vm.prank(noApprove);
        paymaster.deposit(address(token), 1e6);
    }

    function testDepositForCreditsTargetFromPayerAndEmitsDepositFor() public {
        uint256 amount = 250e6;

        vm.expectEmit(true, true, true, true, address(paymaster));
        emit IRathPaymaster.DepositFor(PAYER, USER, address(token), amount);

        vm.prank(PAYER);
        paymaster.depositFor(USER, address(token), amount);

        assertEq(paymaster.balanceOf(USER, address(token)), amount);
        assertEq(paymaster.balanceOf(PAYER, address(token)), 0);
        assertEq(token.balanceOf(address(paymaster)), amount);
        assertEq(token.balanceOf(PAYER), 750e6);
        assertEq(token.balanceOf(USER), 1_000e6);
    }

    function testDepositForCanCreditCallerWhenPayerIsUser() public {
        uint256 amount = 75e6;

        vm.prank(USER);
        paymaster.depositFor(USER, address(token), amount);

        assertEq(paymaster.balanceOf(USER, address(token)), amount);
        assertEq(token.balanceOf(USER), 925e6);
    }

    function testDepositForRevertsForZeroUser() public {
        vm.expectRevert(IRathPaymaster.InvalidUser.selector);
        vm.prank(PAYER);
        paymaster.depositFor(address(0), address(token), 1);
    }

    function testDepositForRevertsForZeroToken() public {
        vm.expectRevert(IRathPaymaster.InvalidToken.selector);
        vm.prank(PAYER);
        paymaster.depositFor(USER, address(0), 1);
    }

    function testDepositForRevertsForZeroAmount() public {
        vm.expectRevert(IRathPaymaster.DepositAmountZero.selector);
        vm.prank(PAYER);
        paymaster.depositFor(USER, address(token), 0);
    }

    function testDepositForRevertsForClosedTargetAccount() public {
        _close(USER);

        vm.expectRevert(IRathPaymaster.AccountAlreadyClosed.selector);
        vm.prank(PAYER);
        paymaster.depositFor(USER, address(token), 1);
    }

    /// @dev A payer whose own account is closed can still fund an open target;
    ///      only the target's state is checked. Documents this behavior.
    function testDepositForAllowedWhenPayerAccountClosedButTargetOpen() public {
        _close(PAYER);

        vm.prank(PAYER);
        paymaster.depositFor(USER, address(token), 10e6);

        assertEq(paymaster.balanceOf(USER, address(token)), 10e6);
    }

    function testSubmitClosureRequestSetsStateAndEmits() public {
        vm.expectEmit(true, false, false, true, address(paymaster));
        emit IRathPaymaster.AccountClosureRequested(USER, block.timestamp);

        vm.prank(USER);
        paymaster.submitAccountClosureRequest();

        (bool isClosed, bool isRequested, uint256 t) = paymaster.getAccountStatus(USER);
        assertFalse(isClosed);
        assertTrue(isRequested);
        assertEq(t, block.timestamp);
    }

    function testSubmitClosureRequestRevertsWhenAlreadyOpen() public {
        vm.startPrank(USER);
        paymaster.submitAccountClosureRequest();

        vm.expectRevert(IRathPaymaster.ClosureRequestAlreadyOpen.selector);
        paymaster.submitAccountClosureRequest();
        vm.stopPrank();
    }

    function testCancelClosureRequestResetsStateAndEmits() public {
        vm.startPrank(USER);
        paymaster.submitAccountClosureRequest();

        vm.expectEmit(true, false, false, false, address(paymaster));
        emit IRathPaymaster.AccountClosureCancelled(USER);
        paymaster.cancelAccountClosureRequest();
        vm.stopPrank();

        (, bool isRequested, uint256 t) = paymaster.getAccountStatus(USER);
        assertFalse(isRequested);
        assertEq(t, 0);
    }

    function testCancelClosureRequestRevertsWhenNoneOpen() public {
        vm.expectRevert(IRathPaymaster.ClosureRequestRequired.selector);
        vm.prank(USER);
        paymaster.cancelAccountClosureRequest();
    }

    /// @dev After cancelling, a user can re-open a fresh request and close normally.
    function testCancelThenReRequestAndClose() public {
        vm.startPrank(USER);
        paymaster.submitAccountClosureRequest();
        paymaster.cancelAccountClosureRequest();
        paymaster.submitAccountClosureRequest();
        skip(paymaster.COOLING_PERIOD());
        paymaster.closeAccount();
        vm.stopPrank();

        (bool isClosed,,) = paymaster.getAccountStatus(USER);
        assertTrue(isClosed);
    }

    function testCloseAccountRevertsWithoutRequest() public {
        vm.expectRevert(IRathPaymaster.ClosureRequestRequired.selector);
        vm.prank(USER);
        paymaster.closeAccount();
    }

    function testCloseAccountRevertsBeforeCoolingPeriod() public {
        vm.prank(USER);
        paymaster.submitAccountClosureRequest();

        uint256 required = block.timestamp + paymaster.COOLING_PERIOD();
        skip(paymaster.COOLING_PERIOD() - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IRathPaymaster.CoolingPeriodNotOver.selector, block.timestamp, required)
        );
        vm.prank(USER);
        paymaster.closeAccount();
    }

    function testCloseAccountSucceedsExactlyAtCoolingBoundary() public {
        vm.prank(USER);
        paymaster.submitAccountClosureRequest();
        skip(paymaster.COOLING_PERIOD());

        vm.expectEmit(true, false, false, false, address(paymaster));
        emit IRathPaymaster.AccountClosed(USER);
        vm.prank(USER);
        paymaster.closeAccount();

        (bool isClosed, bool isRequested,) = paymaster.getAccountStatus(USER);
        assertTrue(isClosed);
        assertFalse(isRequested);
    }

    function testCloseAccountRevertsWhenAlreadyClosed() public {
        _close(USER);

        vm.expectRevert(IRathPaymaster.AccountAlreadyClosed.selector);
        vm.prank(USER);
        paymaster.closeAccount();
    }

    function testClosureRequestRevertsWhenAlreadyClosed() public {
        _close(USER);

        vm.expectRevert(IRathPaymaster.AccountAlreadyClosed.selector);
        vm.prank(USER);
        paymaster.submitAccountClosureRequest();
    }

    function testWithdrawReturnsBalanceAfterCloseAndEmits() public {
        vm.prank(USER);
        paymaster.deposit(address(token), 300e6);
        _close(USER);

        vm.expectEmit(true, true, false, true, address(paymaster));
        emit IRathPaymaster.TokenWithdrawn(USER, address(token), 300e6);

        vm.prank(USER);
        paymaster.withdraw(address(token));

        assertEq(paymaster.balanceOf(USER, address(token)), 0);
        assertEq(token.balanceOf(USER), 1_000e6);
        assertEq(token.balanceOf(address(paymaster)), 0);
    }

    function testWithdrawRevertsWhenAccountNotClosed() public {
        vm.prank(USER);
        paymaster.deposit(address(token), 100e6);

        vm.expectRevert(IRathPaymaster.AccountNotClosed.selector);
        vm.prank(USER);
        paymaster.withdraw(address(token));
    }

    function testWithdrawRevertsForZeroBalance() public {
        _close(USER);

        vm.expectRevert(IRathPaymaster.InsufficientBalance.selector);
        vm.prank(USER);
        paymaster.withdraw(address(token));
    }

    function testWithdrawRevertsOnDoubleWithdraw() public {
        vm.prank(USER);
        paymaster.deposit(address(token), 100e6);
        _close(USER);

        vm.startPrank(USER);
        paymaster.withdraw(address(token));

        vm.expectRevert(IRathPaymaster.InsufficientBalance.selector);
        paymaster.withdraw(address(token));
        vm.stopPrank();
    }

    /// @dev CEI: `withdraw` zeroes the balance before transferring, so a token
    ///      that re-enters `withdraw` mid-transfer cannot drain a second payout.
    function testWithdrawIsReentrancySafe() public {
        ReentrantERC20 reToken = new ReentrantERC20();
        reToken.setPaymaster(paymaster);
        reToken.mint(USER, 100e6);

        vm.startPrank(USER);
        reToken.approve(address(paymaster), type(uint256).max);
        paymaster.deposit(address(reToken), 100e6);
        paymaster.submitAccountClosureRequest();
        vm.stopPrank();
        skip(paymaster.COOLING_PERIOD());
        vm.prank(USER);
        paymaster.closeAccount();

        reToken.arm();

        // The re-entrant inner withdraw hits the already-zeroed balance; the whole
        // call reverts, so there is no double payout (CEI holds).
        vm.expectRevert();
        vm.prank(USER);
        paymaster.withdraw(address(reToken));

        // Nothing was paid out: the paymaster still holds the full deposit.
        assertEq(reToken.balanceOf(USER), 0);
        assertEq(reToken.balanceOf(address(paymaster)), 100e6);
        assertEq(paymaster.balanceOf(USER, address(reToken)), 100e6);
    }

    function testChargeAccountDebitsAndTransfersToFoundation() public {
        vm.prank(USER);
        paymaster.deposit(address(token), 500e6);

        bytes32 root = keccak256("bundle-1");
        vm.expectEmit(true, true, false, true, address(paymaster));
        emit IRathPaymaster.AccountCharged(USER, address(token), 200e6, root);

        vm.prank(RATH_FOUNDATION);
        paymaster.chargeAccount(USER, address(token), 200e6, root);

        assertEq(paymaster.balanceOf(USER, address(token)), 300e6);
        assertEq(token.balanceOf(RATH_FOUNDATION), 200e6);
    }

    function testChargeAccountRevertsForNonFoundation() public {
        vm.prank(USER);
        paymaster.deposit(address(token), 100e6);

        vm.expectRevert(IRathPaymaster.OnlyRathFoundationCanCharge.selector);
        vm.prank(USER);
        paymaster.chargeAccount(USER, address(token), 1, keccak256("x"));
    }

    function testChargeAccountRevertsWhenExceedingBalance() public {
        vm.prank(USER);
        paymaster.deposit(address(token), 100e6);

        vm.expectRevert(IRathPaymaster.InsufficientBalance.selector);
        vm.prank(RATH_FOUNDATION);
        paymaster.chargeAccount(USER, address(token), 100e6 + 1, keccak256("x"));
    }

    function testChargeAccountRevertsWhenAccountClosed() public {
        vm.prank(USER);
        paymaster.deposit(address(token), 100e6);
        _close(USER);

        vm.expectRevert(IRathPaymaster.AccountAlreadyClosed.selector);
        vm.prank(RATH_FOUNDATION);
        paymaster.chargeAccount(USER, address(token), 1, keccak256("x"));
    }

    /// @dev Charging is per-(user,token): charging USER must not touch OTHER's balance.
    function testChargeAccountIsolatesUsers() public {
        vm.prank(USER);
        paymaster.deposit(address(token), 100e6);
        vm.prank(OTHER);
        paymaster.deposit(address(token), 100e6);

        vm.prank(RATH_FOUNDATION);
        paymaster.chargeAccount(USER, address(token), 40e6, keccak256("b"));

        assertEq(paymaster.balanceOf(USER, address(token)), 60e6);
        assertEq(paymaster.balanceOf(OTHER, address(token)), 100e6);
    }

    function testRescueAccountRevertsForNonFoundation() public {
        vm.expectRevert(IRathPaymaster.OnlyRathFoundationCanCharge.selector);
        vm.prank(USER);
        paymaster.rescueAccount(USER, address(token), 1);
    }

    function testRescueAccountRevertsForOpenAccountErc20() public {
        vm.prank(USER);
        paymaster.deposit(address(token), 100e6);

        vm.expectRevert(IRathPaymaster.AccountNotClosed.selector);
        vm.prank(RATH_FOUNDATION);
        paymaster.rescueAccount(USER, address(token), 1);
    }

    function testRescueAccountEthBypassesClosedCheck() public {
        vm.deal(address(paymaster), 5 ether);

        vm.prank(RATH_FOUNDATION);
        paymaster.rescueAccount(USER, address(0), 5 ether); // USER never closed

        assertEq(RATH_FOUNDATION.balance, 5 ether);
        assertEq(address(paymaster).balance, 0);
    }

    /// @dev AUDIT FINDING FIX (rescueAccount shared-pool drain): rescueAccount now
    ///      caps the ERC20 `amount` to the closed user's tracked balance and
    ///      decrements `balances` on rescue. It can therefore neither drain funds
    ///      backing OTHER, still-open users nor leave a stale ledger entry that the
    ///      rescued user could re-withdraw. This test proves the fixed behavior.
    function testRescueAccountCannotExceedUserBalanceOrDrainOtherUsersPool() public {
        vm.prank(USER);
        paymaster.deposit(address(token), 100e6);
        vm.prank(OTHER);
        paymaster.deposit(address(token), 100e6);
        assertEq(token.balanceOf(address(paymaster)), 200e6);

        _close(USER);

        // Attempting to rescue more than USER's own balance must revert -- the
        // OTHER user's 100e6 is not reachable via USER's rescue.
        vm.prank(RATH_FOUNDATION);
        vm.expectRevert(IRathPaymaster.InsufficientBalance.selector);
        paymaster.rescueAccount(USER, address(token), 200e6);

        // A rescue bounded to USER's balance succeeds and debits USER's ledger.
        vm.prank(RATH_FOUNDATION);
        paymaster.rescueAccount(USER, address(token), 100e6);

        assertEq(token.balanceOf(RATH_FOUNDATION), 100e6);
        assertEq(token.balanceOf(address(paymaster)), 100e6); // OTHER's funds intact
        assertEq(paymaster.balanceOf(USER, address(token)), 0); // ledger decremented

        // OTHER remains fully funded and can still withdraw everything.
        assertEq(paymaster.balanceOf(OTHER, address(token)), 100e6);
        vm.startPrank(OTHER);
        paymaster.submitAccountClosureRequest();
        skip(paymaster.COOLING_PERIOD());
        paymaster.closeAccount();
        paymaster.withdraw(address(token));
        vm.stopPrank();
        // OTHER started with 1_000e6, deposited then withdrew 100e6 -> back to 1_000e6.
        assertEq(token.balanceOf(OTHER), 1_000e6);
        assertEq(token.balanceOf(address(paymaster)), 0);
    }

    // ---------------------------------------------------------------------
    // Non-standard tokens
    // ---------------------------------------------------------------------

    /// @dev AUDIT FINDING FIX (fee-on-transfer over-credit): deposit now credits the
    ///      amount actually received (measured via balanceOf delta), not the
    ///      requested `amount`. The ledger therefore matches the pool exactly, and
    ///      the credited balance is fully withdrawable -- the pool stays solvent.
    function testDepositCreditsAmountReceivedForFeeOnTransferToken() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20();
        fee.mint(USER, 100e6);

        vm.startPrank(USER);
        fee.approve(address(paymaster), type(uint256).max);
        paymaster.deposit(address(fee), 100e6);
        vm.stopPrank();

        // Ledger credits only what the pool actually received (90e6 after 10% fee).
        assertEq(paymaster.balanceOf(USER, address(fee)), 90e6);
        assertEq(fee.balanceOf(address(paymaster)), 90e6);

        // The full credited balance is withdrawable -- pool is solvent, no revert.
        vm.startPrank(USER);
        paymaster.submitAccountClosureRequest();
        skip(paymaster.COOLING_PERIOD());
        paymaster.closeAccount();
        paymaster.withdraw(address(fee));
        vm.stopPrank();

        assertEq(paymaster.balanceOf(USER, address(fee)), 0);
        assertEq(fee.balanceOf(address(paymaster)), 0);
    }

    // Fuzz
    function testFuzzDepositThenWithdrawRoundTrips(uint256 amount) public {
        amount = bound(amount, 1, 1_000e6);

        vm.startPrank(USER);
        paymaster.deposit(address(token), amount);
        paymaster.submitAccountClosureRequest();
        skip(paymaster.COOLING_PERIOD());
        paymaster.closeAccount();
        paymaster.withdraw(address(token));
        vm.stopPrank();

        assertEq(paymaster.balanceOf(USER, address(token)), 0);
        assertEq(token.balanceOf(USER), 1_000e6);
    }

    function testFuzzChargeNeverExceedsDeposit(uint256 deposited, uint256 charged) public {
        deposited = bound(deposited, 1, 1_000e6);
        charged = bound(charged, 1, deposited);

        vm.prank(USER);
        paymaster.deposit(address(token), deposited);

        vm.prank(RATH_FOUNDATION);
        paymaster.chargeAccount(USER, address(token), charged, keccak256("f"));

        assertEq(paymaster.balanceOf(USER, address(token)), deposited - charged);
        assertEq(token.balanceOf(RATH_FOUNDATION), charged);
    }

    // helpers
    function _close(address user) private {
        vm.startPrank(user);
        paymaster.submitAccountClosureRequest();
        skip(paymaster.COOLING_PERIOD());
        paymaster.closeAccount();
        vm.stopPrank();
    }
}
