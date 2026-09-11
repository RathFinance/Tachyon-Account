// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0;

/// @title Factory for deploying contracts to deterministic addresses via CREATE3
/// @notice Each deployer (`msg.sender`) has its own namespace for deployed addresses.
interface ICREATE3Factory {
    /// @notice Deploys a contract using a deployer-specific salt.
    function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address deployed);

    /// @notice Predicts the address deployed by `deployer` with `salt`.
    function getDeployed(address deployer, bytes32 salt) external view returns (address deployed);
}
