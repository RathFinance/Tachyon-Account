// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {RathPaymaster} from "../src/RathPaymaster.sol";
import {ICREATE3Factory} from "./ICreate3Factory.sol";

contract DeployRathPaymaster is Script {
    address internal constant CREATE3_FACTORY = 0xeC4086C8c4807CC5c7E9D07Fc4228A4590a5104b;
    address internal constant RATH_FOUNDATION = 0xEafAB774Ab1A3b5748F3eA694F449039E09932BB;
    address internal constant OWNER = 0x55019eEDab2AcB5580bAd02454B22aDf5C37952A;
    bytes32 internal constant SALT = keccak256("rath.fi.paymaster.contract");

    function run() external returns (RathPaymaster paymaster) {
        uint256 deployerPrivateKey = vm.envUint("KEY");
        address deployer = vm.addr(deployerPrivateKey);
        ICREATE3Factory create3 = ICREATE3Factory(CREATE3_FACTORY);
        address predicted = create3.getDeployed(deployer, SALT);

        console.log("CREATE3 salt:", vm.toString(SALT));
        console.log("Deployer:", deployer);
        console.log("Predicted RathPaymaster:", predicted);

        vm.startBroadcast(deployerPrivateKey);

        address deployed = create3.deploy(
            SALT, abi.encodePacked(type(RathPaymaster).creationCode, abi.encode(RATH_FOUNDATION, OWNER))
        );

        vm.stopBroadcast();

        require(deployed == predicted, "unexpected CREATE3 deployment address");
        console.log("RathPaymaster deployed at:", deployed);

        paymaster = RathPaymaster(payable(deployed));
    }
}
