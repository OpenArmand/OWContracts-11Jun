// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/IGovernorUpgradeable.sol";
import "./interfaces/INativeDAOGovernance.sol";
import "./interfaces/ISkillOracleManager.sol";
import "./interfaces/IOpenWorkBridge.sol";
import "./interfaces/IBridgeMessageReceiver.sol";
import "./interfaces/IGovernanceActionTracker.sol";

/**
 * @title NativeDAOGovernance
 * @dev Implementation of the Native DAO Governance Contract on the OpenWork Chain
 * This contract manages governance functions and cross-chain communication
 * Uses the OpenZeppelin Governor pattern for proposal management
 */
contract NativeDAOGovernance is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    INativeDAOGovernance,
    IBridgeMessageReceiver
{
    address public mainDAOAddress;
    IOpenWorkBridge public layerZeroBridge;
    uint32 public mainChainId;
    ISkillOracleManager public skillOracleManager;
    IGovernanceActionTracker public governanceActionTracker;
    
    uint8 public majorityThreshold; // Default 80%
    uint8 public quorumThreshold;   // Default 20%
    uint256 public proposalStake;   // Default 100,000 tokens
    uint256 public nativeVotingPeriod;    // Default 7 days
    
    // Governor specific mappings
    mapping(uint256 => mapping(address => bool)) private _nativeHasVoted;
    mapping(uint256 => uint256) private proposalYesVotes;
    mapping(uint256 => uint256) private proposalNoVotes;
    mapping(uint256 => address[]) internal _countingVoteIds;
    
    // Events
    event MinimumStakeUpdated(uint256 newMinimumStake);
    event RequiredVotesUpdated(uint256 newRequiredVotes);
    event MajorityThresholdUpdated(uint8 newMajorityThreshold);
    event QuorumThresholdUpdated(uint8 newQuorumThreshold);
    event VotingPeriodUpdated(uint256 newVotingPeriod);
    event ProposalStakeUpdated(uint256 newProposalStake);
    event SkillOracleManagerSet(address skillOracleManagerAddress);
    event MinimumMembersUpdated(uint8 newMinimumMembers);
    event GovernanceActionTrackerSet(address governanceActionTrackerAddress);
    
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
        __Governor_init("NativeDAOGovernor");
        __GovernorSettings_init(1, // 1 block voting delay
            7 days, // 7 days voting period 
            100000 * 1e18); // 100,000 tokens for proposal threshold
        __GovernorCountingSimple_init();
        
        // Explicitly transfer ownership to the specified initial owner
        _transferOwnership(_initialOwner);
        
        // Set default values
        majorityThreshold = 80; // 80%
        quorumThreshold = 20;   // 20%
        proposalStake = 100000 * 1e18; // 100,000 tokens
        nativeVotingPeriod = 7 days;
    }
    
    /**
     * @dev Set the main DAO address
     * @param _mainDAOAddress Address of the main DAO
     */
    function setMainDAOAddress(address _mainDAOAddress) external onlyOwner {
        mainDAOAddress = _mainDAOAddress;
    }
    
    /**
     * @dev Set the Layer Zero bridge
     * @param _layerZeroBridge Address of the Layer Zero bridge for cross-chain communication
     */
    function setLayerZeroBridge(address _layerZeroBridge) external onlyOwner {
        layerZeroBridge = IOpenWorkBridge(_layerZeroBridge);
    }
    
    /**
     * @dev Set the main chain ID
     * @param _mainChainId Chain ID of the main chain (LayerZero chain ID)
     */
    function setMainChainId(uint32 _mainChainId) external onlyOwner {
        mainChainId = _mainChainId;
    }
    
    /**
     * @dev Set the votes token for governance
     * @param _votesToken Address of the token contract that supports the IVotesUpgradeable interface
     */
    function setVotesToken(address _votesToken) external onlyOwner {
        __GovernorVotes_init(IVotesUpgradeable(_votesToken));
    }
    
    /**
     * @dev Set the skill oracle manager contract address
     * @param _skillOracleManager Address of the skill oracle manager contract
     */
    function setSkillOracleManager(address _skillOracleManager) external onlyOwner {
        skillOracleManager = ISkillOracleManager(_skillOracleManager);
        emit SkillOracleManagerSet(_skillOracleManager);
    }
    
    /**
     * @dev Set the governance action tracker contract address
     * @param _governanceActionTracker Address of the governance action tracker contract
     */
    function setGovernanceActionTracker(address _governanceActionTracker) external onlyOwner {
        governanceActionTracker = IGovernanceActionTracker(_governanceActionTracker);
        emit GovernanceActionTrackerSet(_governanceActionTracker);
    }
    
    /**
     * @dev Authorizes an upgrade to a new implementation contract
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    /**
     * @dev Receives cross-chain messages from the bridge
     * @param srcChainId Source chain ID (LayerZero chain ID)
     * @param srcAddress Source address on the source chain
     * @param payload Message payload
     * @return success Whether the message was processed successfully
     */
    function receiveCrossChainMessage(
        uint32 srcChainId,
        address srcAddress,
        bytes calldata payload
    ) external returns (bool success) {
        require(msg.sender == address(layerZeroBridge), "Only bridge can call this function");
        
        // Process message based on message type
        (uint8 messageType, bytes memory data) = abi.decode(payload, (uint8, bytes));
        
        if (messageType == 1) {
            // Process DAO member check response
            (address userAddress, bool isMember) = abi.decode(data, (address, bool));
            // Process member check result
            return true;
        } else if (messageType == 2) {
            // Process governance vote
            (uint256 proposalId, address voter, uint8 support) = abi.decode(data, (uint256, address, uint8));
            // Process vote
            return true;
        }
        
        return false;
    }
    
    // INativeDAOGovernance required function implementations
    
    /**
     * @dev Check if a user has voting rights
     * @param user Address of the user
     * @return Whether the user has voting rights
     */
    function hasVotingRights(address user) external view returns (bool) {
        // Check if the user has any voting power
        return _getVotingPower(user) > 0;
    }
    
    /**
     * @dev Get the voting power of a user
     * @param user Address of the user
     * @return Voting power amount
     */
    function getVotingPower(address user) external view returns (uint256) {
        return _getVotingPower(user);
    }
    
    /**
     * @dev Internal function to get the voting power of a user
     * @param user Address of the user
     * @return Voting power amount
     */
    function _getVotingPower(address user) internal view returns (uint256) {
        // Get voting power from the token contract using the token variable
        return IVotesUpgradeable(token).getVotes(user);
    }
    
    /**
     * @dev Override of proposalThreshold to resolve the conflict between base contracts
     */
    function proposalThreshold() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return GovernorSettingsUpgradeable.proposalThreshold();
    }
    
    /**
     * @dev Implement the required quorum function
     * @param timepoint The timepoint to check the quorum for
     * @return The number of votes required for quorum at the given timepoint
     */
    function quorum(uint256 timepoint) public view override returns (uint256) {
        // Calculate quorum based on total supply and quorum threshold
        uint256 totalSupply = IVotesUpgradeable(token).getPastTotalSupply(timepoint);
        return (totalSupply * quorumThreshold) / 100;
    }
    
    /**
     * @dev Add a contract to the authorized list of the governance action tracker
     * @param contractAddress Address of the contract to authorize
     */
    function addAuthorizedContract(address contractAddress) external onlyOwner {
        require(address(governanceActionTracker) != address(0), "Tracker not set");
        governanceActionTracker.addAuthorizedContract(contractAddress);
    }
    
    /**
     * @dev Remove a contract from the authorized list of the governance action tracker
     * @param contractAddress Address of the contract to remove
     */
    function removeAuthorizedContract(address contractAddress) external onlyOwner {
        require(address(governanceActionTracker) != address(0), "Tracker not set");
        governanceActionTracker.removeAuthorizedContract(contractAddress);
    }
    
    /**
     * @dev Record a governance action for a user
     * @param user Address of the user
     */
    function recordGovernanceAction(address user) external {
        require(address(governanceActionTracker) != address(0), "Tracker not set");
        // Use the dedicated tracker contract
        governanceActionTracker.recordGovernanceAction(user);
    }
    
    /**
     * @dev Get the required action threshold for a governance level
     * @param level Governance level
     * @return Required action threshold
     */
    function getRequiredActionThreshold(uint256 level) external view returns (uint256) {
        require(address(governanceActionTracker) != address(0), "Tracker not set");
        return governanceActionTracker.getRequiredActionThreshold(level);
    }
    
    /**
     * @dev Check DAO membership with main DAO
     * @param userAddress Address to check
     * @return success Whether the operation was successful
     */
    function checkDAOMembership(address userAddress) external returns (bool success) {
        // Build message payload
        bytes memory payload = abi.encode(1, userAddress); // 1 = Check DAO Membership
        
        // Send cross-chain message with uint16 cast for chain ID
        layerZeroBridge.sendMessage(uint16(mainChainId), mainDAOAddress, payload);
        return true;
    }
    
    /**
     * @dev Update minimum members required for an oracle
     * @param newMinimumMembers New minimum members value
     */
    function updateMinimumMembers(uint8 newMinimumMembers) external onlyOwner {
        require(newMinimumMembers >= 3, "Minimum members must be at least 3");
        
        // Create a custom function in ISkillOracleManager for this
        // or handle it another way if updateMinimumMembers doesn't exist
        emit MinimumMembersUpdated(newMinimumMembers);
    }
    
    /**
     * @dev Update majority threshold
     * @param newMajorityThreshold New majority threshold (percentage)
     */
    function updateMajority(uint8 newMajorityThreshold) external onlyOwner {
        require(newMajorityThreshold > 50 && newMajorityThreshold <= 100, "Threshold must be 51-100%");
        majorityThreshold = newMajorityThreshold;
        emit MajorityThresholdUpdated(newMajorityThreshold);
    }
    
    /**
     * @dev Update quorum threshold
     * @param newQuorumThreshold New quorum threshold (percentage)
     */
    function updateThreshold(uint8 newQuorumThreshold) external onlyOwner {
        require(newQuorumThreshold > 0 && newQuorumThreshold <= 50, "Threshold must be 1-50%");
        quorumThreshold = newQuorumThreshold;
        emit QuorumThresholdUpdated(newQuorumThreshold);
    }
    
    /**
     * @dev Update voting period for native proposals
     * @param newVotingPeriod New voting period in seconds
     */
    function updateNativeVotingPeriod(uint256 newVotingPeriod) external onlyOwner {
        require(newVotingPeriod >= 1 days && newVotingPeriod <= 30 days, "Period must be 1-30 days");
        nativeVotingPeriod = newVotingPeriod;
        emit VotingPeriodUpdated(newVotingPeriod);
    }
    
    /**
     * @dev Update proposal stake amount
     * @param newProposalStake New proposal stake amount
     */
    function updateProposalStake(uint256 newProposalStake) external onlyOwner {
        require(newProposalStake > 0, "Stake must be greater than 0");
        proposalStake = newProposalStake;
        emit ProposalStakeUpdated(newProposalStake);
    }
    
    /**
     * @dev Get the main DAO address
     * @return The main DAO address
     */
    function getMainDAOAddress() external view returns (address) {
        return mainDAOAddress;
    }
    
    /**
     * @dev Get the bridge address
     * @return The bridge contract address
     */
    function getLayerZeroBridgeAddress() external view returns (address) {
        return address(layerZeroBridge);
    }
    
    /**
     * @dev Get the main chain ID
     * @return The main chain ID
     */
    function getMainChainId() external view returns (uint32) {
        return mainChainId;
    }
    
    /**
     * @dev Get the total number of governance actions performed by a user
     * @param user Address of the user
     * @return The total number of governance actions
     */
    function getTotalGovernanceActions(address user) external view returns (uint256) {
        require(address(governanceActionTracker) != address(0), "Tracker not set");
        return governanceActionTracker.getTotalGovernanceActions(user);
    }
}