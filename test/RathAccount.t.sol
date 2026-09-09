// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {IRathAccount} from "../src/interfaces/IRathAccount.sol";
import {RathAccount} from "../src/RathAccount.sol";

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

contract RathAccountTest is Test {
    address private constant RATH_FOUNDATION = address(0x1001);
    address private constant OWNER = address(0x1002);
    address private constant STRANGER = address(0x1003);

    RathAccount private account;
    MockERC20 private token;

    function setUp() public {
        token = new MockERC20();
        account = new RathAccount(RATH_FOUNDATION, OWNER, address(token));

        token.mint(OWNER, 1_000e6);
        token.mint(STRANGER, 1_000e6);

        vm.prank(OWNER);
        token.approve(address(account), type(uint256).max);

        vm.prank(STRANGER);
        token.approve(address(account), type(uint256).max);
    }

    function testConstructorSetsRolesAndToken() public view {
        assertEq(account.RathFoundation(), RATH_FOUNDATION);
        assertEq(account.owner(), OWNER);
        assertEq(address(account.token()), address(token));
        assertEq(account.COOLING_PERIOD(), 7 days);
        assertEq(account.version(), "0.0.1");
    }

    function testDepositPullsTokensAndEmits() public {
        uint256 amount = 100e6;

        vm.expectEmit(true, false, false, true, address(account));
        emit IRathAccount.RathAccountDeposit(OWNER, address(token), amount);

        vm.prank(OWNER);
        account.deposit(amount);

        assertEq(token.balanceOf(address(account)), amount);
        assertEq(token.balanceOf(OWNER), 900e6);
    }

    function testDepositAllowsAnyDepositor() public {
        // deposit has no owner gate: any address may fund the account.
        uint256 amount = 250e6;

        vm.prank(STRANGER);
        account.deposit(amount);

        assertEq(token.balanceOf(address(account)), amount);
        assertEq(token.balanceOf(STRANGER), 750e6);
    }

    function testDepositRevertsForZeroAmount() public {
        vm.expectRevert(IRathAccount.DepositAmountZero.selector);
        vm.prank(OWNER);
        account.deposit(0);
    }

    function testDepositRevertsWhenClosed() public {
        _closeAccount();

        vm.expectRevert(IRathAccount.AccountAlreadyClosed.selector);
        vm.prank(OWNER);
        account.deposit(1);
    }

    /// @dev `deposit` is `payable` but never reads `msg.value`; ETH sent alongside a
    ///      deposit is silently trapped in the contract. This documents that behavior.
    function testDepositTrapsAttachedEth() public {
        vm.deal(OWNER, 1 ether);

        vm.prank(OWNER);
        account.deposit{value: 1 ether}(100e6);

        // ETH is retained by the contract with no credit or refund path for the depositor.
        assertEq(address(account).balance, 1 ether);
    }

    function testSubmitClosureRequestSetsStateAndEmits() public {
        vm.expectEmit(true, false, false, true, address(account));
        emit IRathAccount.RathAccountClosureRequested(OWNER, address(token), block.timestamp);

        vm.prank(OWNER);
        account.submitAccountClosureRequest();

        assertTrue(account.isAccountClosingRequestOpen());
        assertEq(account.accountClosingRequestTime(), block.timestamp);
    }

    function testSubmitClosureRequestOnlyOwner() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(STRANGER);
        account.submitAccountClosureRequest();
    }

    function testSubmitClosureRequestRevertsWhenClosed() public {
        _closeAccount();

        vm.expectRevert(IRathAccount.AccountAlreadyClosed.selector);
        vm.prank(OWNER);
        account.submitAccountClosureRequest();
    }

    function testCloseAccountTransfersBalanceToOwnerAndEmits() public {
        vm.prank(OWNER);
        account.deposit(400e6);

        vm.prank(OWNER);
        account.submitAccountClosureRequest();

        skip(account.COOLING_PERIOD());

        vm.expectEmit(true, false, false, true, address(account));
        emit IRathAccount.RathAccountClosed(OWNER, 400e6);

        vm.prank(OWNER);
        account.closeAccount();

        assertTrue(account.isAccountClosed());
        assertEq(token.balanceOf(OWNER), 1_000e6);
        assertEq(token.balanceOf(address(account)), 0);
    }

    function testCloseAccountOnlyOwner() public {
        vm.prank(OWNER);
        account.submitAccountClosureRequest();
        skip(account.COOLING_PERIOD());

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(STRANGER);
        account.closeAccount();
    }

    function testCloseAccountRevertsWithoutClosureRequest() public {
        vm.expectRevert(IRathAccount.ClosureRequestRequired.selector);
        vm.prank(OWNER);
        account.closeAccount();
    }

    function testCloseAccountRevertsBeforeCoolingPeriodOver() public {
        vm.prank(OWNER);
        account.submitAccountClosureRequest();

        uint256 requiredTime = account.accountClosingRequestTime() + account.COOLING_PERIOD();

        // One second short of the cooling period.
        skip(account.COOLING_PERIOD() - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IRathAccount.CoolingPeriodNotOver.selector, block.timestamp, requiredTime)
        );
        vm.prank(OWNER);
        account.closeAccount();
    }

    function testCloseAccountSucceedsExactlyAtCoolingBoundary() public {
        vm.prank(OWNER);
        account.submitAccountClosureRequest();

        // Exactly at the boundary: block.timestamp == requestTime + COOLING_PERIOD.
        skip(account.COOLING_PERIOD());

        vm.prank(OWNER);
        account.closeAccount();

        assertTrue(account.isAccountClosed());
    }

    function testCloseAccountRevertsWhenAlreadyClosed() public {
        _closeAccount();

        vm.expectRevert(IRathAccount.AccountAlreadyClosed.selector);
        vm.prank(OWNER);
        account.closeAccount();
    }

    function testChargeAccountTransfersToFoundationAndEmits() public {
        vm.prank(OWNER);
        account.deposit(500e6);

        bytes32 root = keccak256("bundle-1");

        vm.expectEmit(true, false, false, true, address(account));
        emit IRathAccount.RathAccountCharged(OWNER, address(token), 200e6, root);

        vm.prank(RATH_FOUNDATION);
        account.chargeAccount(200e6, root);

        assertEq(token.balanceOf(RATH_FOUNDATION), 200e6);
        assertEq(token.balanceOf(address(account)), 300e6);
    }

    function testChargeAccountOnlyRathFoundation() public {
        vm.prank(OWNER);
        account.deposit(100e6);

        vm.expectRevert(IRathAccount.OnlyRathFoundationCanCharge.selector);
        vm.prank(OWNER);
        account.chargeAccount(1, keccak256("x"));
    }

    function testChargeAccountRevertsWhenClosed() public {
        vm.prank(OWNER);
        account.deposit(100e6);
        _closeAccount();

        vm.expectRevert(IRathAccount.AccountAlreadyClosed.selector);
        vm.prank(RATH_FOUNDATION);
        account.chargeAccount(1, keccak256("x"));
    }

    /// @dev `chargeAccount` has no accounting: it can transfer the entire deposited
    ///      balance regardless of what any charge should be. This documents that the
    ///      only bound is the contract's token balance itself.
    function testChargeAccountCanDrainEntireBalance() public {
        vm.prank(OWNER);
        account.deposit(500e6);

        vm.prank(RATH_FOUNDATION);
        account.chargeAccount(500e6, keccak256("drain"));

        assertEq(token.balanceOf(address(account)), 0);
        assertEq(token.balanceOf(RATH_FOUNDATION), 500e6);
    }

    function testChargeAccountRevertsWhenExceedingBalance() public {
        vm.prank(OWNER);
        account.deposit(100e6);

        // No explicit balance check exists; the underlying token transfer reverts.
        vm.expectRevert();
        vm.prank(RATH_FOUNDATION);
        account.chargeAccount(200e6, keccak256("over"));
    }

    function testRescueAccountRevertsWhenNotClosed() public {
        vm.expectRevert(IRathAccount.AccountNotClosed.selector);
        vm.prank(RATH_FOUNDATION);
        account.rescueAccount(1, address(token));
    }

    function testRescueAccountOnlyRathFoundation() public {
        vm.expectRevert(IRathAccount.OnlyRathFoundationCanCharge.selector);
        vm.prank(OWNER);
        account.rescueAccount(1, address(token));
    }

    function testRescueAccountRescuesStrayTokensAfterClose() public {
        _closeAccount();

        // Tokens sent directly to the contract after closure are strays with no owner path.
        token.mint(address(account), 42e6);

        vm.prank(RATH_FOUNDATION);
        account.rescueAccount(42e6, address(token));

        assertEq(token.balanceOf(RATH_FOUNDATION), 42e6);
        assertEq(token.balanceOf(address(account)), 0);
    }

    function testRescueAccountRescuesEthAfterClose() public {
        _closeAccount();

        vm.deal(address(account), 3 ether);

        vm.prank(RATH_FOUNDATION);
        account.rescueAccount(3 ether, address(0));

        assertEq(RATH_FOUNDATION.balance, 3 ether);
        assertEq(address(account).balance, 0);
    }

    // helpers
    function _closeAccount() private {
        vm.prank(OWNER);
        account.submitAccountClosureRequest();
        skip(account.COOLING_PERIOD());
        vm.prank(OWNER);
        account.closeAccount();
    }
}
