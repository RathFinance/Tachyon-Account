// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;


import {Script} from "forge-std/Script.sol";
import {TachyonAccount} from "../src/TachyonAccount.sol";

contract DeployTachyonAccount is Script {
    address constant token = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant rathFoundation = 0xEafAB774Ab1A3b5748F3eA694F449039E09932BB;
    address constant Owner = 0x55019eEDab2AcB5580bAd02454B22aDf5C37952A;
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        new TachyonAccount(
            rathFoundation,
            Owner,
            token
        );
        vm.stopBroadcast();
    }
}