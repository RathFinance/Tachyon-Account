// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RathPaymaster} from "../src/RathPaymaster.sol";
import {ICREATE3Factory} from "./ICreate3Factory.sol";

/// @notice Deploys the RathPaymaster implementation and puts an ERC-1967 proxy in front of it
///         at a CREATE3 address, so the paymaster keeps one address across chains and upgrades.
/// @dev The proxy's constructor runs `initialize`, so the deployed address is never left
///      uninitialized for someone else to claim.
contract DeployRathPaymaster is Script {
    address internal constant CREATE3_FACTORY = 0xeC4086C8c4807CC5c7E9D07Fc4228A4590a5104b;
    address internal constant RATH_FOUNDATION = 0xEafAB774Ab1A3b5748F3eA694F449039E09932BB;
    address internal constant OWNER = 0xEb53041450537aC14EC44fF00b82dB214e45F4bf;
    bytes32 internal constant SALT = keccak256("rath.fi.paymaster.proxy");

    function run() external returns (RathPaymaster paymaster) {
        uint256 deployerPrivateKey = vm.envUint("KEY");
        address deployer = vm.addr(deployerPrivateKey);
        ICREATE3Factory create3 = ICREATE3Factory(CREATE3_FACTORY);
        address predicted = create3.getDeployed(deployer, SALT);

        console.log("CREATE3 salt:", vm.toString(SALT));
        console.log("Deployer:", deployer);
        console.log("Predicted RathPaymaster proxy:", predicted);

        bytes memory initData = abi.encodeCall(RathPaymaster.initialize, (RATH_FOUNDATION, OWNER));

        vm.startBroadcast(deployerPrivateKey);

        address implementation = address(new RathPaymaster());
        address deployed = create3.deploy(
            SALT, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData))
        );

        vm.stopBroadcast();

        require(deployed == predicted, "unexpected CREATE3 deployment address");

        paymaster = RathPaymaster(payable(deployed));
        require(paymaster.owner() == OWNER, "owner not initialized");
        require(paymaster.rathFoundation() == RATH_FOUNDATION, "foundation not initialized");

        console.log("RathPaymaster implementation deployed at:", implementation);
        console.log("RathPaymaster proxy deployed at:", deployed);
        console.log("Version:", paymaster.version());
    }
}
