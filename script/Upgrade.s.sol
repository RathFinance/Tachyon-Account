// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {RathPaymaster} from "../src/RathPaymaster.sol";

/// @notice Deploys a fresh RathPaymaster implementation and points the existing proxy at it.
/// @dev Must be broadcast by the proxy's owner; `_authorizeUpgrade` rejects anyone else.
///      Set `PROXY` to the paymaster proxy address and `KEY` to the owner's key.
contract UpgradeRathPaymaster is Script {
    function run() external returns (address implementation) {
        uint256 ownerPrivateKey = vm.envUint("KEY");
        address owner = vm.addr(ownerPrivateKey);
        RathPaymaster paymaster = RathPaymaster(payable(vm.envAddress("PROXY")));

        require(paymaster.owner() == owner, "broadcaster is not the proxy owner");

        console.log("Proxy:", address(paymaster));
        console.log("Version before:", paymaster.version());

        vm.startBroadcast(ownerPrivateKey);

        implementation = address(new RathPaymaster());
        // Empty data: state already exists in the proxy, so there is nothing to re-initialize.
        // A future upgrade that adds storage should pass an encoded `reinitializer` call here.
        paymaster.upgradeToAndCall(implementation, "");

        vm.stopBroadcast();

        console.log("New implementation:", implementation);
        console.log("Version after:", paymaster.version());
    }
}
