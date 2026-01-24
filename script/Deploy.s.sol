// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/src/Script.sol";
import { AgiArenaCore } from "../src/core/AgiArenaCore.sol";
import { ResolutionDAO } from "../src/dao/ResolutionDAO.sol";

/// @title Deploy
/// @notice Deployment script for AgiArenaCore and ResolutionDAO to Base mainnet
/// @dev Libraries (BettingLib, MatchingLib) are internal and linked at compile time - NOT separately deployed
contract Deploy is Script {
    /// @notice Base Mainnet USDC address (official Circle contract)
    address public constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @notice Run the deployment script
    /// @return core The deployed AgiArenaCore contract instance
    /// @return resolutionDAO The deployed ResolutionDAO contract instance
    function run() public returns (AgiArenaCore core, ResolutionDAO resolutionDAO) {
        // Load private key from environment with validation
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(deployerPrivateKey != 0, "DEPLOYER_PRIVATE_KEY not set or invalid");
        address deployer = vm.addr(deployerPrivateKey);

        // Fee recipient defaults to deployer, can be overridden via environment
        address feeRecipient = vm.envOr("PLATFORM_FEE_RECIPIENT", deployer);

        // Load keeper addresses from environment (required for bootstrap)
        address keeper1 = vm.envAddress("KEEPER1_ADDRESS");
        address keeper2 = vm.envAddress("KEEPER2_ADDRESS");
        require(keeper1 != address(0), "KEEPER1_ADDRESS not set or zero");
        require(keeper2 != address(0), "KEEPER2_ADDRESS not set or zero");
        require(keeper1 != keeper2, "KEEPER1_ADDRESS and KEEPER2_ADDRESS must be different");

        console.log("=== AgiArena Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Fee Recipient:", feeRecipient);
        console.log("USDC Address:", USDC_BASE);
        console.log("Chain ID:", block.chainid);
        console.log("");
        console.log("=== Keeper Bootstrap Addresses ===");
        console.log("KEEPER1:", keeper1);
        console.log("KEEPER2:", keeper2);

        vm.startBroadcast(deployerPrivateKey);

        // Get current nonce to predict contract addresses
        uint64 currentNonce = vm.getNonce(deployer);

        // Pre-compute ResolutionDAO address (will be deployed at nonce+1)
        // AgiArenaCore will be at nonce, ResolutionDAO at nonce+1
        address predictedResolutionDAO = vm.computeCreateAddress(deployer, currentNonce + 1);
        console.log("");
        console.log("=== Address Prediction ===");
        console.log("Predicted ResolutionDAO:", predictedResolutionDAO);

        // Step 1: Deploy AgiArenaCore with predicted ResolutionDAO as resolver
        core = new AgiArenaCore(USDC_BASE, feeRecipient, predictedResolutionDAO);
        console.log("");
        console.log("=== Contract Deployments ===");
        console.log("AgiArenaCore deployed to:", address(core));

        // Step 2: Deploy ResolutionDAO with deployer as initial keeper
        // The deployer serves as bootstrap keeper to add KEEPER1 and KEEPER2
        resolutionDAO = new ResolutionDAO(deployer, address(core));
        console.log("ResolutionDAO deployed to:", address(resolutionDAO));

        // Verify prediction was correct
        require(address(resolutionDAO) == predictedResolutionDAO, "ResolutionDAO address mismatch!");

        // Step 3: Bootstrap KEEPER1
        // With only deployer as keeper, they can propose, vote, and execute
        console.log("");
        console.log("=== Keeper Bootstrap Sequence ===");
        console.log("Step 1: Adding KEEPER1...");
        uint256 proposal1 = resolutionDAO.proposeKeeper(keeper1);
        console.log("  Proposal ID:", proposal1);
        resolutionDAO.voteOnKeeperProposal(proposal1, true);
        console.log("  Deployer voted: true");
        resolutionDAO.executeKeeperProposal(proposal1);
        console.log("  KEEPER1 added successfully!");

        // Step 4: Bootstrap KEEPER2
        // Now both deployer and KEEPER1 must vote, but only deployer has private key in script
        // Deployer proposes KEEPER2 and votes, but KEEPER1 must vote separately
        console.log("");
        console.log("Step 2: Proposing KEEPER2 (requires KEEPER1 vote to complete)...");
        uint256 proposal2 = resolutionDAO.proposeKeeper(keeper2);
        console.log("  Proposal ID:", proposal2);
        resolutionDAO.voteOnKeeperProposal(proposal2, true);
        console.log("  Deployer voted: true");
        console.log("  IMPORTANT: KEEPER1 must call voteOnKeeperProposal(", proposal2, ", true)");
        console.log("  Then anyone can call executeKeeperProposal(", proposal2, ")");

        vm.stopBroadcast();

        // Log post-deployment instructions
        console.log("");
        console.log("=== Current Keeper Status ===");
        console.log("Active Keepers:", resolutionDAO.getKeeperCount());
        console.log("  [0] Deployer:", deployer);
        console.log("  [1] KEEPER1:", keeper1);
        console.log("");
        console.log("=== POST-DEPLOYMENT ACTIONS REQUIRED ===");
        console.log("");
        console.log("1. KEEPER1 must complete KEEPER2 addition:");
        console.log("   cast send", address(resolutionDAO));
        console.log("   'voteOnKeeperProposal(uint256,bool)' ", proposal2, " true");
        console.log("   --private-key $KEEPER1_PRIVATE_KEY --rpc-url $BASE_RPC_URL");
        console.log("");
        console.log("2. Then execute the proposal:");
        console.log("   cast send", address(resolutionDAO));
        console.log("   'executeKeeperProposal(uint256)' ", proposal2);
        console.log("   --private-key $KEEPER1_PRIVATE_KEY --rpc-url $BASE_RPC_URL");
        console.log("");
        console.log("3. After KEEPER2 is added, propose deployer removal (decentralization):");
        console.log("   KEEPER1 or KEEPER2 calls proposeKeeperRemoval(", deployer, ")");
        console.log("   All 3 keepers vote, then execute to remove deployer");
        console.log("");
        console.log("=== Address Capture ===");
        console.log("Run: ./script/capture-addresses.sh");
        console.log("");
        console.log("=== Contract Verification ===");
        console.log("AgiArenaCore: https://basescan.org/address/", address(core));
        console.log("ResolutionDAO: https://basescan.org/address/", address(resolutionDAO));
    }
}
