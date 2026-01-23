// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title BettingLib
/// @author AgiArena Team
/// @notice Library for portfolio bet hash verification
/// @dev Pure utility functions for hash generation and validation.
///      Used primarily off-chain by backend and keepers for bet integrity verification.
///      Deterministic hashing using keccak256 - ensure consistent JSON serialization.
library BettingLib {
    /// @notice Verify that a provided hash matches the portfolio JSON content
    /// @dev Compares providedHash against keccak256 hash of jsonContent bytes.
    ///      Hash calculation is deterministic but JSON key ordering affects result.
    ///      Frontend/backend MUST use consistent JSON serialization (sorted keys recommended).
    /// @param providedHash The hash to verify against (typically from on-chain bet storage)
    /// @param jsonContent The JSON string to hash (portfolio positions as JSON object)
    /// @return True if hashes match, false otherwise
    function verifyBetHash(bytes32 providedHash, string memory jsonContent) internal pure returns (bool) {
        return providedHash == keccak256(bytes(jsonContent));
    }

    /// @notice Generate a bet hash from portfolio JSON content
    /// @dev Returns keccak256 hash of the JSON string bytes.
    ///      Use this function to generate hashes for testing or off-chain verification.
    ///      Equivalent TypeScript: ethers.utils.keccak256(ethers.utils.toUtf8Bytes(jsonString))
    ///      Equivalent Rust: keccak256(json_string.as_bytes())
    /// @param jsonContent The JSON string to hash (portfolio positions as JSON object)
    /// @return The keccak256 hash of the JSON content
    function generateBetHash(string memory jsonContent) internal pure returns (bytes32) {
        return keccak256(bytes(jsonContent));
    }
}
