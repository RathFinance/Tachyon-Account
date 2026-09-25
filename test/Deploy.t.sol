// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RathPaymaster} from "../src/RathPaymaster.sol";
import {ICREATE3Factory} from "../script/ICreate3Factory.sol";

/// @dev Stand-in for the canonical CREATE3 factory, namespacing salts per deployer exactly as it does.
contract MockCREATE3Factory is ICREATE3Factory {
    function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address) {
        return CREATE3.deployDeterministic(msg.value, creationCode, keccak256(abi.encodePacked(msg.sender, salt)));
    }

    function getDeployed(address deployer, bytes32 salt) external view returns (address) {
        return CREATE3.predictDeterministicAddress(keccak256(abi.encodePacked(deployer, salt)), address(this));
    }
}

/// @notice Exercises the deployment path used by `script/Deploy.s.sol`: a CREATE3-addressed
///         ERC-1967 proxy whose constructor initializes the paymaster in the same transaction.
contract DeployTest is Test {
    address private constant RATH_FOUNDATION = address(0x1001);
    address private constant OWNER = address(0x1002);
    address private constant DEPLOYER = address(0x1003);
    address private constant ATTACKER = address(0x1004);

    bytes32 private constant SALT = keccak256("rath.fi.paymaster.proxy");

    /// @dev `uint256(keccak256("eip1967.proxy.implementation")) - 1`.
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MockCREATE3Factory private factory;

    function setUp() public {
        factory = new MockCREATE3Factory();
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    /// @dev Mirrors the creation code assembled by the deploy script. `caller` is the CREATE3
    ///      deployer, which is what the resulting address is derived from.
    function _deploy(address caller, address implementation) private returns (address deployed) {
        bytes memory initData = abi.encodeCall(RathPaymaster.initialize, (RATH_FOUNDATION, OWNER));
        bytes memory creationCode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData));

        vm.prank(caller);
        deployed = factory.deploy(SALT, creationCode);
    }

    function testDeploysToPredictedAddressAndInitializes() public {
        address predicted = factory.getDeployed(DEPLOYER, SALT);
        address implementation = address(new RathPaymaster());

        address deployed = _deploy(DEPLOYER, implementation);

        assertEq(deployed, predicted);
        assertEq(_implementationOf(deployed), implementation);

        RathPaymaster paymaster = RathPaymaster(payable(deployed));
        assertEq(paymaster.owner(), OWNER);
        assertEq(paymaster.rathFoundation(), RATH_FOUNDATION);
    }

    /// @dev The whole point of CREATE3: the address depends on the salt alone, so deploying a
    ///      different implementation (and therefore different proxy init code) under the same salt
    ///      still lands on the same address.
    function testAddressIsIndependentOfImplementation() public {
        address predicted = factory.getDeployed(DEPLOYER, SALT);
        uint256 snapshot = vm.snapshotState();

        address firstImpl = address(new RathPaymaster());
        assertEq(_deploy(DEPLOYER, firstImpl), predicted);

        vm.revertToState(snapshot);

        // Shift the nonce so this implementation lands on a different address than the first.
        new RathPaymaster();
        address secondImpl = address(new RathPaymaster());
        assertTrue(secondImpl != firstImpl);

        address second = _deploy(DEPLOYER, secondImpl);

        assertEq(second, predicted);
        assertEq(_implementationOf(second), secondImpl);
    }

    /// @dev Initialization happens inside the proxy constructor, so the deployed address is
    ///      never briefly ownerless for someone to claim.
    function testDeployedProxyCannotBeReinitialized() public {
        address deployed = _deploy(DEPLOYER, address(new RathPaymaster()));

        vm.expectRevert();
        vm.prank(ATTACKER);
        RathPaymaster(payable(deployed)).initialize(ATTACKER, ATTACKER);

        assertEq(RathPaymaster(payable(deployed)).owner(), OWNER);
    }

    /// @dev Only the configured deployer can reach that address, since the factory salts by sender.
    function testAttackerCannotOccupyTheDeployerAddress() public {
        address predicted = factory.getDeployed(DEPLOYER, SALT);

        address attackerDeployed = _deploy(ATTACKER, address(new RathPaymaster()));

        assertTrue(attackerDeployed != predicted);
        assertEq(attackerDeployed, factory.getDeployed(ATTACKER, SALT));

        // The deployer's address is still free.
        assertEq(_deploy(DEPLOYER, address(new RathPaymaster())), predicted);
    }
}
