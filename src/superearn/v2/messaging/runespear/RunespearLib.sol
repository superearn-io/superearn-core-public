// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

/**
 * @title RunespearLib
 * @notice Library for encoding/decoding Runespear protocol messages
 * @dev Implements chain-agnostic intent/RPC messaging format
 */
library RunespearLib {
    // === Constants ===
    bytes32 public constant PROTOCOL_SIGNATURE = keccak256("runespear");
    uint8 public constant FORMAT_VERSION_1 = 1;

    // === Custom Errors ===
    error InvalidProtocolSignature();
    error UnsupportedFormatVersion(uint8 version);
    error InvalidMessageLength();

    // === Structs ===

    /**
     * @notice Message header containing protocol metadata
     * @param protocolId Protocol identifier (must be PROTOCOL_SIGNATURE)
     * @param version Format version
     */
    struct Header {
        bytes32 protocolId;
        uint8 version;
    }

    /**
     * @notice Complete message structure
     * @param header Message header
     * @param predicate Intent or function selector
     * @param args Encoded arguments
     */
    struct Message {
        Header header;
        bytes4 predicate;
        bytes args;
    }

    // === Encoding Functions ===

    /**
     * @notice Encode a Runespear message
     * @param predicate The intent or function selector
     * @param args The encoded arguments
     * @return Encoded message bytes
     */
    function encodeMessage(bytes4 predicate, bytes memory args) internal pure returns (bytes memory) {
        Header memory header = Header({ protocolId: PROTOCOL_SIGNATURE, version: FORMAT_VERSION_1 });

        return abi.encode(header, predicate, args);
    }

    // === Decoding Functions ===

    /**
     * @notice Decode a Runespear message
     * @param data The encoded message bytes
     * @return message The decoded message structure
     */
    function decodeMessage(bytes memory data) internal pure returns (Message memory message) {
        if (data.length < 160) revert InvalidMessageLength();

        (Header memory header, bytes4 predicate, bytes memory args) = abi.decode(data, (Header, bytes4, bytes));

        // Validate protocol signature
        if (header.protocolId != PROTOCOL_SIGNATURE) {
            revert InvalidProtocolSignature();
        }

        // Validate version
        if (header.version != FORMAT_VERSION_1) {
            revert UnsupportedFormatVersion(header.version);
        }

        message = Message({ header: header, predicate: predicate, args: args });
    }

    // === Predicate Helper Functions ===

    /**
     * @notice Hash a function signature with a salt to create a unique predicate
     * @param signature The function signature (e.g., "transfer(address,uint256)")
     * @param salt The salt to mix with the signature for uniqueness
     * @return The 4-byte predicate selector
     */
    function hashPredicate(string memory signature, bytes32 salt) internal pure returns (bytes4) {
        return bytes4(keccak256(abi.encodePacked(signature, salt)));
    }

    /**
     * @notice Hash a function signature without salt (standard selector)
     * @param signature The function signature
     * @return The standard 4-byte selector
     */
    function hashPredicateStandard(string memory signature) internal pure returns (bytes4) {
        return bytes4(keccak256(bytes(signature)));
    }
}
