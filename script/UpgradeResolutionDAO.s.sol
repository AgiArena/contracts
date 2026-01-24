// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/src/Script.sol";
import { ResolutionDAO } from "../src/dao/ResolutionDAO.sol";

/// @title UpgradeResolutionDAO
/// @notice Deployment script to upgrade ResolutionDAO with flexible consensus support
/// @dev Deploys new ResolutionDAO and registers all 3 keepers
contract UpgradeResolutionDAO is Script {
    /// @notice Existing AgiArenaCore address (don't redeploy)
    address public constant CORE_ADDRESS = 0xdbDD446F158cA403e70521497CC33E0A53205f74;

    /// @notice Run the upgrade script
    /// @return resolutionDAO The newly deployed ResolutionDAO contract instance
    function run() public returns (ResolutionDAO resolutionDAO) {
        // Load private key from environment with validation
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(deployerPrivateKey != 0, "DEPLOYER_PRIVATE_KEY not set or invalid");
        address deployer = vm.addr(deployerPrivateKey);

        // All 3 keeper addresses (deployer is also a keeper in current setup)
        // keeper1 container uses deployer key, keeper2 uses KEEPER1, keeper3 uses KEEPER2
        address keeper1 = deployer; // 0xC0d3ca67da45613e7C5b2d55F09b00B3c99721f4
        address keeper2 = vm.envAddress("KEEPER1_ADDRESS"); // 0xC0D3C8DFd3445fd2e4dfED9D11b5B7032B3BD1ac
        address keeper3 = vm.envAddress("KEEPER2_ADDRESS"); // 0xC0D3C397033aa62245aF6A734D582C956ABd7Fa9

        require(keeper2 != address(0), "KEEPER1_ADDRESS not set or zero");
        require(keeper3 != address(0), "KEEPER2_ADDRESS not set or zero");
        require(keeper1 != keeper2 && keeper1 != keeper3 && keeper2 != keeper3, "Keeper addresses must be different");

        console.log("=== ResolutionDAO Upgrade ===");
        console.log("Deployer:", deployer);
        console.log("Existing Core:", CORE_ADDRESS);
        console.log("Chain ID:", block.chainid);
        console.log("");
        console.log("=== Keeper Addresses ===");
        console.log("KEEPER1:", keeper1);
        console.log("KEEPER2:", keeper2);
        console.log("KEEPER3:", keeper3);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy new ResolutionDAO with deployer as initial keeper
        resolutionDAO = new ResolutionDAO(deployer, CORE_ADDRESS);
        console.log("");
        console.log("=== Contract Deployed ===");
        console.log("New ResolutionDAO:", address(resolutionDAO));

        // Step 2: Deployer (keeper1) is already added during construction
        // Add KEEPER2 - deployer can propose and vote, then execute (1-of-1 until more keepers)
        console.log("");
        console.log("=== Adding Keepers ===");
        console.log("Deployer (keeper1) already added during construction");

        console.log("");
        console.log("Adding KEEPER2...");
        uint256 proposal2 = resolutionDAO.proposeKeeper(keeper2);
        resolutionDAO.voteOnKeeperProposal(proposal2, true);
        resolutionDAO.executeKeeperProposal(proposal2);
        console.log("  KEEPER2 added!");

        // Step 3: Add KEEPER3 - now need 2-of-2 (deployer + keeper2)
        // Deployer can propose and vote, keeper2 must vote separately
        console.log("");
        console.log("Adding KEEPER3...");
        uint256 proposal3 = resolutionDAO.proposeKeeper(keeper3);
        resolutionDAO.voteOnKeeperProposal(proposal3, true);
        console.log("  Deployer voted, KEEPER2 must vote next");
        console.log("  Proposal ID:", proposal3);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Current Status ===");
        console.log("Active Keepers:", resolutionDAO.getKeeperCount());
        console.log("");
        console.log("=== UPDATE THESE CONFIGS ===");
        console.log("1. backend/.env: RESOLUTION_DAO_ADDRESS=", address(resolutionDAO));
        console.log("2. keeper/.env: RESOLUTION_DAO_ADDRESS=", address(resolutionDAO));
        console.log("3. frontend/.env: NEXT_PUBLIC_RESOLUTION_CONTRACT_ADDRESS=", address(resolutionDAO));
        console.log("");
        console.log("=== Verify on Basescan ===");
        console.log("https://basescan.org/address/", address(resolutionDAO));
    }
}
