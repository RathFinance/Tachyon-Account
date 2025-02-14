// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;


import {Script} from "forge-std/Script.sol";
import {TachyonAccount} from "../src/TachyonAccount.sol";

contract DeployTachyonAccount is Script {
    address constant token = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant rathFoundation = 0xEafAB774Ab1A3b5748F3eA694F449039E09932BB;
    address constant Owner = 0x3F0c940097741cfA247e6560191b881c9A7b658b;
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