// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/src/Test.sol";
import { Deploy } from "../script/Deploy.s.sol";
import { AgiArenaCore } from "../src/core/AgiArenaCore.sol";
import { ResolutionDAO } from "../src/dao/ResolutionDAO.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Mock USDC token for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @title DeployTest
/// @notice Tests for the deployment script
contract DeployTest is Test {
    Deploy public deployScript;
    MockUSDC public mockUsdc;

    // Expected Base mainnet USDC address
    address public constant EXPECTED_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Test keeper addresses (derived from test private keys)
    address public constant KEEPER1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public constant KEEPER2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    function setUp() public {
        deployScript = new Deploy();
        mockUsdc = new MockUSDC();
    }

    /// @notice Verify the default collateral constant is set correctly
    function test_DefaultCollateral_Constant() public view {
        assertEq(deployScript.DEFAULT_COLLATERAL(), EXPECTED_USDC, "Default collateral address mismatch");
    }

    /// @notice Test deployment with mock private key
    function test_Deployment() public {
        // Set up mock environment variables
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
        vm.setEnv("KEEPER1_ADDRESS", vm.toString(KEEPER1));
        vm.setEnv("KEEPER2_ADDRESS", vm.toString(KEEPER2));
        vm.setEnv("COLLATERAL_TOKEN_ADDRESS", vm.toString(address(mockUsdc)));

        // Create fresh deploy script to pick up env vars
        Deploy freshDeploy = new Deploy();
        (AgiArenaCore core, ResolutionDAO resolutionDAO) = freshDeploy.run();

        // Verify AgiArenaCore deployment
        assertTrue(address(core) != address(0), "AgiArenaCore not deployed");
        assertEq(address(core.COLLATERAL_TOKEN()), address(mockUsdc), "Collateral token not set correctly");
        assertEq(core.PLATFORM_FEE_BPS(), 10, "Platform fee not 10 bps");
        assertEq(core.nextBetId(), 0, "nextBetId should start at 0");

        // Verify ResolutionDAO deployment
        assertTrue(address(resolutionDAO) != address(0), "ResolutionDAO not deployed");
        assertEq(resolutionDAO.AGIARENA_CORE(), address(core), "ResolutionDAO should reference AgiArenaCore");

        // Verify keeper bootstrap (deployer + KEEPER1 should be keepers)
        assertEq(resolutionDAO.getKeeperCount(), 2, "Should have 2 keepers after bootstrap");
        assertTrue(resolutionDAO.isKeeper(KEEPER1), "KEEPER1 should be a keeper");
    }

    /// @notice Test deployment with custom fee recipient
    function test_Deployment_CustomFeeRecipient() public {
        address customFeeRecipient = address(0xBEEF);

        // Set up mock environment variables BEFORE creating deploy script
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
        vm.setEnv("PLATFORM_FEE_RECIPIENT", vm.toString(customFeeRecipient));
        vm.setEnv("KEEPER1_ADDRESS", vm.toString(KEEPER1));
        vm.setEnv("KEEPER2_ADDRESS", vm.toString(KEEPER2));
        vm.setEnv("COLLATERAL_TOKEN_ADDRESS", vm.toString(address(mockUsdc)));

        // Create fresh deploy script to pick up env vars
        Deploy freshDeploy = new Deploy();
        (AgiArenaCore core, ) = freshDeploy.run();

        // Verify fee recipient
        assertEq(core.FEE_RECIPIENT(), customFeeRecipient, "Custom fee recipient not set");
    }

    /// @notice Test deployment defaults fee recipient to deployer
    function test_Deployment_DefaultFeeRecipient() public {
        // Use a known test private key
        uint256 privateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address expectedDeployer = vm.addr(privateKey);

        // Set up mock environment - no PLATFORM_FEE_RECIPIENT set
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(privateKey));
        // Clear any existing fee recipient env var
        vm.setEnv("PLATFORM_FEE_RECIPIENT", "");
        vm.setEnv("KEEPER1_ADDRESS", vm.toString(KEEPER1));
        vm.setEnv("KEEPER2_ADDRESS", vm.toString(KEEPER2));
        vm.setEnv("COLLATERAL_TOKEN_ADDRESS", vm.toString(address(mockUsdc)));

        // Create fresh deploy script to pick up env vars
        Deploy freshDeploy = new Deploy();
        (AgiArenaCore core, ) = freshDeploy.run();

        // Fee recipient should default to deployer
        assertEq(core.FEE_RECIPIENT(), expectedDeployer, "Fee recipient should default to deployer");
    }

    /// @notice Test ResolutionDAO keeper bootstrap sequence
    function test_ResolutionDAO_KeeperBootstrap() public {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPrivateKey);

        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(deployerPrivateKey));
        vm.setEnv("KEEPER1_ADDRESS", vm.toString(KEEPER1));
        vm.setEnv("KEEPER2_ADDRESS", vm.toString(KEEPER2));
        vm.setEnv("COLLATERAL_TOKEN_ADDRESS", vm.toString(address(mockUsdc)));

        Deploy freshDeploy = new Deploy();
        (, ResolutionDAO resolutionDAO) = freshDeploy.run();

        // Verify deployer is a keeper (initial keeper)
        assertTrue(resolutionDAO.isKeeper(deployer), "Deployer should be initial keeper");

        // Verify KEEPER1 was added during bootstrap
        assertTrue(resolutionDAO.isKeeper(KEEPER1), "KEEPER1 should be added during bootstrap");

        // Verify KEEPER2 proposal exists but not yet executed (requires KEEPER1 vote)
        // The proposal for KEEPER2 should be proposal ID 1 (proposal 0 was KEEPER1)
        ResolutionDAO.KeeperProposal memory proposal = resolutionDAO.getProposal(1);
        assertEq(proposal.keeper, KEEPER2, "Proposal 1 should be for KEEPER2");
        assertFalse(proposal.executed, "KEEPER2 proposal should not be executed yet");
        assertEq(proposal.votesFor, 1, "Deployer should have voted for KEEPER2");
    }
}
