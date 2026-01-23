// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/src/Test.sol";
import { BettingLib } from "../src/libraries/BettingLib.sol";

/// @title BettingLibTest
/// @notice Unit tests for BettingLib hash verification functions
contract BettingLibTest is Test {
    /// @notice Test generateBetHash produces deterministic output
    function test_GenerateBetHash_DeterministicOutput() public pure {
        string memory json = '{"0x1234567890abcdef1234567890abcdef12345678":1}';

        bytes32 hash1 = BettingLib.generateBetHash(json);
        bytes32 hash2 = BettingLib.generateBetHash(json);

        assertEq(hash1, hash2, "Hash should be deterministic");
    }

    /// @notice Test generateBetHash produces correct keccak256 hash
    function test_GenerateBetHash_CorrectKeccak256() public pure {
        string memory json = '{"0x1234567890abcdef1234567890abcdef12345678":1}';

        bytes32 expected = keccak256(bytes(json));
        bytes32 actual = BettingLib.generateBetHash(json);

        assertEq(actual, expected, "Hash should match keccak256(bytes(json))");
    }

    /// @notice Test verifyBetHash returns true for matching hashes
    function test_VerifyBetHash_MatchingHash() public pure {
        string memory json = '{"0xmarket1":1,"0xmarket2":0}';
        bytes32 hash = keccak256(bytes(json));

        bool result = BettingLib.verifyBetHash(hash, json);

        assertTrue(result, "Should return true for matching hash");
    }

    /// @notice Test verifyBetHash returns false for non-matching hashes
    function test_VerifyBetHash_NonMatchingHash() public pure {
        string memory json = '{"0xmarket1":1}';
        bytes32 wrongHash = keccak256(bytes("different content"));

        bool result = BettingLib.verifyBetHash(wrongHash, json);

        assertFalse(result, "Should return false for non-matching hash");
    }

    /// @notice Test empty string produces a deterministic hash
    function test_GenerateBetHash_EmptyString() public pure {
        string memory empty = "";

        bytes32 hash = BettingLib.generateBetHash(empty);
        bytes32 expected = keccak256(bytes(""));

        assertEq(hash, expected, "Empty string should produce deterministic hash");
    }

    /// @notice Test verifyBetHash with empty string
    function test_VerifyBetHash_EmptyString() public pure {
        string memory empty = "";
        bytes32 hash = keccak256(bytes(""));

        bool result = BettingLib.verifyBetHash(hash, empty);

        assertTrue(result, "Should verify empty string correctly");
    }

    /// @notice Test that different JSON produces different hashes
    function test_GenerateBetHash_DifferentInputsDifferentHashes() public pure {
        string memory json1 = '{"0xmarket1":1}';
        string memory json2 = '{"0xmarket1":0}';

        bytes32 hash1 = BettingLib.generateBetHash(json1);
        bytes32 hash2 = BettingLib.generateBetHash(json2);

        assertTrue(hash1 != hash2, "Different JSON should produce different hashes");
    }

    /// @notice Test JSON key ordering affects hash
    function test_GenerateBetHash_KeyOrderingMatters() public pure {
        // These are semantically equivalent JSON but have different byte representations
        string memory json1 = '{"a":1,"b":2}';
        string memory json2 = '{"b":2,"a":1}';

        bytes32 hash1 = BettingLib.generateBetHash(json1);
        bytes32 hash2 = BettingLib.generateBetHash(json2);

        assertTrue(hash1 != hash2, "Key ordering should affect hash (sort keys before hashing!)");
    }

    /// @notice Test large portfolio JSON (simulating many markets)
    function test_GenerateBetHash_LargePortfolio() public pure {
        // Build a larger JSON string simulating multiple markets
        string memory largeJson = '{"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":1,'
            '"0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb":0,'
            '"0xcccccccccccccccccccccccccccccccccccccccc":1,'
            '"0xdddddddddddddddddddddddddddddddddddddddd":0,'
            '"0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":1}';

        bytes32 hash = BettingLib.generateBetHash(largeJson);
        bool verified = BettingLib.verifyBetHash(hash, largeJson);

        assertTrue(verified, "Should handle larger JSON portfolios");
    }

    /// @notice Fuzz test for verifyBetHash consistency
    function testFuzz_VerifyBetHash_AlwaysMatchesGenerated(string memory randomJson) public pure {
        bytes32 generatedHash = BettingLib.generateBetHash(randomJson);
        bool result = BettingLib.verifyBetHash(generatedHash, randomJson);

        assertTrue(result, "Generated hash should always verify");
    }

    /// @notice Fuzz test for hash uniqueness with different inputs
    function testFuzz_GenerateBetHash_DifferentInputs(string memory input1, string memory input2) public pure {
        vm.assume(keccak256(bytes(input1)) != keccak256(bytes(input2)));

        bytes32 hash1 = BettingLib.generateBetHash(input1);
        bytes32 hash2 = BettingLib.generateBetHash(input2);

        assertTrue(hash1 != hash2, "Different inputs should produce different hashes");
    }

    /// @notice Test special characters in JSON
    function test_GenerateBetHash_SpecialCharacters() public pure {
        string memory jsonWithEscapes = '{"key":"value\\nwith\\tnewlines"}';

        bytes32 hash = BettingLib.generateBetHash(jsonWithEscapes);
        bool verified = BettingLib.verifyBetHash(hash, jsonWithEscapes);

        assertTrue(verified, "Should handle special characters correctly");
    }

    /// @notice Test unicode in JSON
    function test_GenerateBetHash_Unicode() public pure {
        string memory jsonWithUnicode = '{"name":"test\u00e9"}';

        bytes32 hash = BettingLib.generateBetHash(jsonWithUnicode);
        bool verified = BettingLib.verifyBetHash(hash, jsonWithUnicode);

        assertTrue(verified, "Should handle unicode correctly");
    }

    /// @notice Test sequential verification with matching and non-matching hashes
    /// @dev Validates library behavior when multiple verifications happen in sequence
    function test_VerifyBetHash_SequentialVerification() public pure {
        string memory json1 = '{"0xmarket1":1}';
        string memory json2 = '{"0xmarket2":0}';

        bytes32 correctHash1 = BettingLib.generateBetHash(json1);
        bytes32 correctHash2 = BettingLib.generateBetHash(json2);

        // Verify correct hashes match their content
        assertTrue(BettingLib.verifyBetHash(correctHash1, json1), "First correct hash should verify");
        assertTrue(BettingLib.verifyBetHash(correctHash2, json2), "Second correct hash should verify");

        // Verify swapped hashes fail (cross-verification)
        assertFalse(BettingLib.verifyBetHash(correctHash1, json2), "Hash1 should not verify json2");
        assertFalse(BettingLib.verifyBetHash(correctHash2, json1), "Hash2 should not verify json1");

        // Verify original hashes still work after failed verifications
        assertTrue(BettingLib.verifyBetHash(correctHash1, json1), "First hash should still verify after failures");
        assertTrue(BettingLib.verifyBetHash(correctHash2, json2), "Second hash should still verify after failures");
    }
}
