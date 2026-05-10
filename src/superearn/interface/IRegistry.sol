// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

/**
 * @title IRegistry
 * @notice Interface for Yearn Vault Registry contract
 * @dev This interface corresponds to Registry.vy version 0.2.11
 */
interface IRegistry {
    // Events
    event NewRelease(uint256 indexed release_id, address template, string api_version);
    event NewVault(address indexed token, uint256 indexed vault_id, address vault, string api_version);
    event NewExperimentalVault(address indexed token, address indexed deployer, address vault, string api_version);
    event NewGovernance(address governance);
    event VaultTagged(address vault, string tag);

    // View functions for public variables
    function numReleases() external view returns (uint256);
    function releases(uint256) external view returns (address);
    function numVaults(address) external view returns (uint256);
    function vaults(address, uint256) external view returns (address);
    function tokens(uint256) external view returns (address);
    function numTokens() external view returns (uint256);
    function isRegistered(address) external view returns (bool);
    function governance() external view returns (address);
    function pendingGovernance() external view returns (address);
    function tags(address) external view returns (string memory);
    function banksy(address) external view returns (bool);

    // Governance functions
    function setGovernance(address governance) external;
    function acceptGovernance() external;

    // Registry functions
    function latestRelease() external view returns (string memory);
    function latestVault(address token) external view returns (address);
    function newRelease(address vault) external;

    function newVault(
        address token,
        address guardian,
        address rewards,
        string memory name,
        string memory symbol,
        uint256 releaseDelta
    )
        external
        returns (address);

    function newExperimentalVault(
        address token,
        address governance,
        address guardian,
        address rewards,
        string memory name,
        string memory symbol,
        uint256 releaseDelta
    )
        external
        returns (address);

    function endorseVault(address vault, uint256 releaseDelta) external;

    // Tagging functions
    function setBanksy(address tagger, bool allowed) external;
    function tagVault(address vault, string memory tag) external;
}
