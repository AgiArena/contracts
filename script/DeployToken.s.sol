// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/src/Script.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/// @title DeployToken
/// @notice Deployment script for MockERC20 token (e.g., IND on L3)
contract DeployToken is Script {
    /// @notice Run the deployment script
    /// @return token The deployed MockERC20 contract instance
    function run() public returns (MockERC20 token) {
        // Load private key from environment with validation
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(deployerPrivateKey != 0, "DEPLOYER_PRIVATE_KEY not set or invalid");
        address deployer = vm.addr(deployerPrivateKey);

        // Token configuration from environment
        string memory tokenName = vm.envOr("TOKEN_NAME", string("Index Token"));
        string memory tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("IND"));
        uint8 tokenDecimals = uint8(vm.envOr("TOKEN_DECIMALS", uint256(18)));

        // Premine configuration
        address premineAddress = vm.envOr("PREMINE_ADDRESS", deployer);
        uint256 premineAmount = vm.envOr("PREMINE_AMOUNT", uint256(1_000_000 * 10**18)); // Default: 1M tokens

        console.log("=== Token Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Token Name:", tokenName);
        console.log("Token Symbol:", tokenSymbol);
        console.log("Token Decimals:", tokenDecimals);
        console.log("Premine Address:", premineAddress);
        console.log("Premine Amount:", premineAmount);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MockERC20 token
        token = new MockERC20(
            tokenName,
            tokenSymbol,
            tokenDecimals,
            premineAddress,
            premineAmount
        );

        console.log("=== Deployment Complete ===");
        console.log("Token deployed to:", address(token));
        console.log("");
        console.log("To add to deploy-config.json:");
        console.log("  collateralToken.address:", address(token));

        vm.stopBroadcast();
    }
}
