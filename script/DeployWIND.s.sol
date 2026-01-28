// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/src/Script.sol";
import { WIND } from "../src/mocks/WIND.sol";

/// @title DeployWIND
/// @notice Deployment script for Wrapped IND (WIND) token on Index L3
contract DeployWIND is Script {
    function run() public returns (WIND wind) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(deployerPrivateKey != 0, "DEPLOYER_PRIVATE_KEY not set");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== WIND Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        wind = new WIND();
        console.log("WIND deployed to:", address(wind));

        vm.stopBroadcast();
    }
}
