// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IGovernanceActionTracker.sol";
import "./interfaces/IOpenWorkBridge.sol";
import "./interfaces/IBridgeMessageReceiver.sol";

/**
 * @title GovernanceActionTracker
 * @dev Implementation of the Governance Action Tracker Contract
 * This contract tracks governance actions across multiple contracts and chains
 * It communicates with other chains via LayerZero Bridge
 */
contract GovernanceActionTracker is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IGovernanceActionTracker,
    IBridgeMessageReceiver
{
    // Cross-chain communication
    IOpenWorkBridge public layerZeroBridge;
    mapping(uint16 => address) public chainIdToTrackerAddress;
    
    // Governance participation tracking
    mapping(address => uint256) private governanceActions;
    
    // Governance participation thresholds
    mapping(uint256 => uint256) private levelActionThresholds;
    
    // Authorized contracts that can record governance actions
    mapping(address => bool) public authorizedContracts;
    
    // Events
    event GovernanceActionRecorded(address user, uint256 totalActions);
    event ContractAuthorized(address contractAddress);
    event ContractUnauthorized(address contractAddress);
    event LayerZeroBridgeSet(address bridgeAddress);
    event ChainTrackerAddressSet(uint16 chainId, address trackerAddress);
    event ActionThresholdUpdated(uint256 level, uint256 threshold);
    
    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initialize the contract with minimal settings
     * @param _initialOwner Address of the initial owner of the contract
     */
    function initialize(
        address _initialOwner
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // Explicitly transfer ownership to the specified initial owner
        _transferOwnership(_initialOwner);
        
        // Set up default governance action thresholds
        levelActionThresholds[1] = 1;    // Level 1: 1 action
        levelActionThresholds[2] = 5;    // Level 2: 5 actions
        levelActionThresholds[3] = 20;   // Level 3: 20 actions
    }
    
    /**
     * @dev Authorizes an upgrade to a new implementation contract
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    /**
     * @dev Set the Layer Zero bridge
     * @param _layerZeroBridge Address of the Layer Zero bridge for cross-chain communication
     */
    function setLayerZeroBridge(address _layerZeroBridge) external override onlyOwner {
        layerZeroBridge = IOpenWorkBridge(_layerZeroBridge);
        emit LayerZeroBridgeSet(_layerZeroBridge);
    }
    
    /**
     * @dev Set tracker address for a specific chain
     * @param chainId Chain ID (LayerZero chain ID)
     * @param trackerAddress Address of the tracker on that chain
     */
    function setChainTrackerAddress(uint16 chainId, address trackerAddress) external onlyOwner {
        require(chainId != 0, "Invalid chain ID");
        require(trackerAddress != address(0), "Invalid tracker address");
        chainIdToTrackerAddress[chainId] = trackerAddress;
        emit ChainTrackerAddressSet(chainId, trackerAddress);
    }
    
    /**
     * @dev Add a contract to the authorized list
     * @param contractAddress Address of the contract to authorize
     */
    function addAuthorizedContract(address contractAddress) external override onlyOwner {
        require(contractAddress != address(0), "Invalid address");
        authorizedContracts[contractAddress] = true;
        emit ContractAuthorized(contractAddress);
    }
    
    /**
     * @dev Remove a contract from the authorized list
     * @param contractAddress Address of the contract to remove
     */
    function removeAuthorizedContract(address contractAddress) external override onlyOwner {
        authorizedContracts[contractAddress] = false;
        emit ContractUnauthorized(contractAddress);
    }
    
    /**
     * @dev Record a governance action for a user
     * @param user Address of the user
     */
    function recordGovernanceAction(address user) external override {
        // Only owner, this contract, or authorized contracts can record governance actions
        require(
            msg.sender == owner() || 
            msg.sender == address(this) || 
            authorizedContracts[msg.sender], 
            "Unauthorized"
        );
        
        governanceActions[user]++;
        emit GovernanceActionRecorded(user, governanceActions[user]);
    }
    
    /**
     * @dev Record a governance action with a specific weight for a user
     * @param user Address of the user
     * @param actionWeight Weight of the governance action
     */
    function recordGovernanceActionWithWeight(address user, uint256 actionWeight) external override {
        // Only owner, this contract, or authorized contracts can record governance actions
        require(
            msg.sender == owner() || 
            msg.sender == address(this) || 
            authorizedContracts[msg.sender], 
            "Unauthorized"
        );
        
        governanceActions[user] += actionWeight;
        emit GovernanceActionRecorded(user, governanceActions[user]);
    }
    
    /**
     * @dev Get the total number of governance actions performed by a user
     * @param user Address of the user
     * @return The total number of governance actions
     */
    function getTotalGovernanceActions(address user) external view override returns (uint256) {
        return governanceActions[user];
    }
    
    /**
     * @dev Update the required action thresholds for different levels
     * @param level Level to update
     * @param threshold New threshold value
     */
    function updateRequiredActionThreshold(uint256 level, uint256 threshold) external override onlyOwner {
        require(level > 0 && level <= 3, "Invalid level");
        require(threshold > 0, "Invalid threshold");
        levelActionThresholds[level] = threshold;
        emit ActionThresholdUpdated(level, threshold);
    }
    
    /**
     * @dev Get the required action threshold for a governance level
     * @param level Governance level
     * @return Required action threshold
     */
    function getRequiredActionThreshold(uint256 level) external view override returns (uint256) {
        require(level > 0 && level <= 3, "Invalid level");
        return levelActionThresholds[level];
    }
    
    /**
     * @dev Check if a user has completed sufficient governance actions for a level
     * @param user Address of the user
     * @param level Governance level
     * @return Whether user has completed the required actions
     */
    function hasCompletedGovernanceActions(address user, uint256 level) external view override returns (bool) {
        require(level > 0 && level <= 3, "Invalid level");
        return governanceActions[user] >= levelActionThresholds[level];
    }
    
    /**
     * @dev Send a cross-chain governance action record
     * @param chainId Destination chain ID (LayerZero chain ID)
     * @param user Address of the user
     * @return success Whether the operation was successful
     */
    function sendCrossChainGovernanceAction(uint16 chainId, address user) external returns (bool success) {
        // Only owner, this contract, or authorized contracts can record governance actions
        require(
            msg.sender == owner() || 
            msg.sender == address(this) || 
            authorizedContracts[msg.sender], 
            "Unauthorized"
        );
        
        address targetAddress = chainIdToTrackerAddress[chainId];
        require(targetAddress != address(0), "No tracker registered for chain");
        
        // Increment locally
        governanceActions[user]++;
        emit GovernanceActionRecorded(user, governanceActions[user]);
        
        // Build message payload
        bytes memory payload = abi.encode(10, abi.encode(user)); // 10 = Governance Action Record
        
        // Send cross-chain message
        layerZeroBridge.sendMessage(chainId, targetAddress, payload);
        return true;
    }
    
    /**
     * @dev Receives cross-chain messages from the bridge
     * @param payload Message payload
     * @return success Whether the message was processed successfully
     */
    function receiveCrossChainMessage(
        uint16,  // srcChainId - unused
        address, // srcAddress - unused
        bytes calldata payload
    ) external override returns (bool success) {
        require(msg.sender == address(layerZeroBridge), "Only bridge can call this function");
        
        // Process message based on message type
        (uint8 messageType, bytes memory data) = abi.decode(payload, (uint8, bytes));
        
        if (messageType == 10) {
            // Process governance action record request from another chain
            address user = abi.decode(data, (address));
            
            // Record the governance action
            // Note: We're trusting this came from an authorized source since the bridge validates that
            governanceActions[user]++;
            emit GovernanceActionRecorded(user, governanceActions[user]);
            return true;
        }
        
        return false;
    }
}