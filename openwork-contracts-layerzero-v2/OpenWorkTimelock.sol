// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title OpenWorkTimelock
 * @dev Timelock controller for governance operations
 */
contract OpenWorkTimelock is 
    Initializable, 
    TimelockControllerUpgradeable, 
    UUPSUpgradeable, 
    OwnableUpgradeable 
{
    /**
     * @dev Initializer for OpenWorkTimelock
     * @param minDelay The minimum delay for timelock operations
     * @param proposers The addresses that can propose operations
     * @param executors The addresses that can execute operations
     * Note: This contract sets itself as the admin
     */
    function initialize(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors
    ) initializer public {
        __TimelockController_init(minDelay, proposers, executors, address(this));
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
    }
    
    /**
     * @dev Function to authorize an upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}