// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice A simple ERC20 token for testing and L3 deployment
/// @dev Used to deploy IND token on the Index L3 chain
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    /// @notice Deploy a new MockERC20 token
    /// @param name_ Token name (e.g., "Index Token")
    /// @param symbol_ Token symbol (e.g., "IND")
    /// @param decimals_ Token decimals (e.g., 18)
    /// @param premineAddress Address to receive initial token supply
    /// @param premineAmount Initial token supply to mint
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address premineAddress,
        uint256 premineAmount
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        if (premineAmount > 0) {
            _mint(premineAddress, premineAmount);
        }
    }

    /// @notice Returns the number of decimals used for token amounts
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint additional tokens (for testing)
    /// @param to Address to mint to
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
