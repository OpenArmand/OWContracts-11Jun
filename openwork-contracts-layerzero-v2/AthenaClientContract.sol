// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title IOpenWorkBridge
 * @dev Interface for the OpenWork LayerZero bridge
 */
interface IOpenWorkBridge {
    function sendMessage(
        uint32 destinationChainId,
        address receiver,
        bytes calldata data
    ) external payable returns (bytes32 messageId);
    
    function estimateFee(
        uint32 destinationChainId,
        address receiver,
        bytes calldata data
    ) external view returns (uint256 fee);
}

/**
 * @title INativeAthenaContract
 * @dev Interface for the Native Athena Contract
 */
interface INativeAthenaContract {
    // Dispute functions
    function raiseDispute(uint256 jobId, string calldata disputeHash, string calldata oracleName, uint256 fee) external payable returns (uint256 disputeId);
    function createDispute(uint256 jobId, string memory reason) external payable returns (uint256);
    function submitEvidence(uint256 disputeId, string calldata evidenceHash) external returns (bool success);
    function voteOnDispute(uint256 disputeId, bool inFavor, string calldata reasonHash) external returns (bool success);
    function resolveDispute(uint256 disputeId, address recipient) external returns (bool success);
    function escalateDispute(uint256 disputeId) external returns (bool success);
    function claimDisputedAmount(uint256 disputeId, uint256 feeAmount) external;
    
    // Oracle functions
    function createOracle(string calldata name, string calldata description) external returns (bool success);
    function addOracleMember(string calldata oracleName, address member) external returns (bool success);
    function removeOracleMember(string calldata oracleName, address member) external returns (bool success);
    function activateOracle(string calldata oracleName) external returns (bool success);
    function deactivateOracle(string calldata oracleName) external returns (bool success);
    function isActive(string calldata oracleName) external view returns (bool isActive);
    
    // Skill functions
    function requestSkillVerification(string calldata skillName, string calldata oracleName, string calldata evidenceHash) external payable returns (bool success);
    function voteOnSkillVerification(address applicant, string calldata skillName, bool inFavor, string calldata reasonHash) external returns (bool success);
    function verifySkill(address user, string memory skill, string memory proofHash, uint256 feeAmount) external;
    
    // Question functions
    function askAthena(string calldata questionHash, string calldata oracleName, uint256 fee) external payable returns (uint256 questionId);
    function voteOnQuestion(uint256 questionId, bool inFavor, string calldata reasonHash) external returns (bool success);
    
    // Security functions
    function reportMaliciousMember(string calldata oracleName, address member, string calldata evidenceHash) external returns (bool success);
}

/**
 * @title AthenaClientContract
 * @dev Client contract for interacting with the Athena dispute resolution service using LayerZero
 */
contract AthenaClientContract is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    // Address of the LayerZero bridge
    address public bridge;
    
    // Address of the native Athena contract on the main chain
    address public nativeAthenaContractAddress;
    
    // Chain ID of the OpenWork chain (LayerZero chain ID format)
    uint32 public openWorkChainId;
    
    // Mapping of message ID to status
    mapping(bytes32 => bool) public messageProcessed;
    
    // Events
    event DisputeRaised(bytes32 indexed messageId, uint256 jobId, string disputeHash);
    event SkillVerificationRequested(bytes32 indexed messageId, address user, string skill, string proofHash);
    event MessageReceived(bytes32 indexed messageId, bytes data);
    event DisputedAmountClaimed(bytes32 indexed messageId, uint256 disputeId);
    event QuestionAsked(bytes32 indexed messageId, string question, string contextHash, string oracleName);
    event DisputeCreated(bytes32 indexed messageId, uint256 jobId, string reason);
    event EvidenceSubmitted(bytes32 indexed messageId, uint256 disputeId, string evidence);
    event DisputeVoteCast(bytes32 indexed messageId, uint256 disputeId, bool inFavor, string reason);
    event Initialized(address initializer);
    
    /**
     * @dev Constructor - empty for proxy pattern
     */
    constructor() {}
    
    /**
     * @dev Initialize the contract (replaces constructor for proxy pattern)
     * @param initialOwner Address of the initial owner
     */
    function initialize(address initialOwner) public initializer {
        // Initialize base contracts
        __Ownable_init(initialOwner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        emit Initialized(initialOwner);
    }
    
    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    /**
     * @dev Set the LayerZero bridge address
     * @param _bridge Address of the LayerZero bridge
     */
    function setBridge(address _bridge) external onlyOwner {
        require(_bridge != address(0), "Bridge address cannot be zero");
        bridge = _bridge;
    }
    
    /**
     * @dev Set the native Athena contract address
     * @param _nativeAthenaContractAddress Address of the native Athena contract
     */
    function setNativeAthenaContractAddress(address _nativeAthenaContractAddress) external onlyOwner {
        require(_nativeAthenaContractAddress != address(0), "Native Athena contract address cannot be zero");
        nativeAthenaContractAddress = _nativeAthenaContractAddress;
    }
    
    /**
     * @dev Set the OpenWork chain ID
     * @param _openWorkChainId Chain ID of the OpenWork chain (LayerZero format)
     */
    function setOpenWorkChainId(uint32 _openWorkChainId) external onlyOwner {
        require(_openWorkChainId > 0, "Chain ID must be greater than zero");
        openWorkChainId = _openWorkChainId;
    }
    
    /**
     * @dev Receive message from the bridge
     * This function is called by the bridge when a message arrives from the main chain
     * @param sourceChainId The source chain ID
     * @param sourceAddress The source address (sender of the message)
     * @param data The message data
     */
    function receiveMessage(
        uint32 sourceChainId,
        address sourceAddress,
        bytes calldata data
    ) external {
        // Only the bridge should be able to call this
        require(msg.sender == bridge, "Caller is not the bridge");
        
        // Generate a unique message ID for tracking
        bytes32 messageId = keccak256(abi.encodePacked(
            sourceChainId,
            sourceAddress,
            data,
            block.timestamp
        ));
        
        require(!messageProcessed[messageId], "Message already processed");
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        // Emit event - applications can listen to this to get the response
        emit MessageReceived(messageId, data);
        
        // Implementation for processing specific message types could be added here
    }
    
    /**
     * @dev Raise a dispute
     * @param jobId The ID of the job
     * @param disputeHash Hash of the dispute details
     * @param oracleName Name of the oracle to use
     * @return messageId The ID of the message
     */
    function raiseDispute(
        uint256 jobId,
        string memory disputeHash,
        string memory oracleName
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.raiseDispute.selector,
            jobId,
            disputeHash,
            oracleName,
            msg.value // Fee amount
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        // Emit event
        emit DisputeRaised(messageId, jobId, disputeHash);
        
        return messageId;
    }
    
    /**
     * @dev Create a dispute (legacy function)
     * @param jobId The ID of the job
     * @param reason The reason for the dispute
     * @return messageId The ID of the message
     */
    function createDispute(
        uint256 jobId,
        string memory reason
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.createDispute.selector,
            jobId,
            reason
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        // Emit event
        emit DisputeCreated(messageId, jobId, reason);
        
        return messageId;
    }
    
    /**
     * @dev Submit evidence for a dispute
     * @param disputeId The ID of the dispute
     * @param evidence The evidence data or hash
     * @return messageId The ID of the message
     */
    function submitEvidence(
        uint256 disputeId,
        string memory evidence
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.submitEvidence.selector,
            disputeId,
            evidence
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        // Emit event
        emit EvidenceSubmitted(messageId, disputeId, evidence);
        
        return messageId;
    }
    
    /**
     * @dev Vote on a dispute
     * @param disputeId The ID of the dispute
     * @param inFavor Whether to vote in favor of the dispute
     * @param reason The reason for the vote
     * @return messageId The ID of the message
     */
    function voteOnDispute(
        uint256 disputeId,
        bool inFavor,
        string memory reason
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.voteOnDispute.selector,
            disputeId,
            inFavor,
            reason
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        // Emit event
        emit DisputeVoteCast(messageId, disputeId, inFavor, reason);
        
        return messageId;
    }
    
    /**
     * @dev Resolve a dispute
     * @param disputeId The ID of the dispute
     * @param recipient The address to receive funds when resolved
     * @return messageId The ID of the message
     */
    function resolveDispute(
        uint256 disputeId,
        address recipient
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.resolveDispute.selector,
            disputeId,
            recipient
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        return messageId;
    }
    
    /**
     * @dev Escalate a dispute
     * @param disputeId The ID of the dispute
     * @return messageId The ID of the message
     */
    function escalateDispute(
        uint256 disputeId
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.escalateDispute.selector,
            disputeId
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        return messageId;
    }
    
    /**
     * @dev Create an oracle
     * @param name The name of the oracle
     * @param description The description of the oracle
     * @return messageId The ID of the message
     */
    function createOracle(
        string memory name,
        string memory description
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.createOracle.selector,
            name,
            description
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        return messageId;
    }
    
    /**
     * @dev Add a member to an oracle
     * @param oracleName The name of the oracle
     * @param member The address of the member to add
     * @return messageId The ID of the message
     */
    function addOracleMember(
        string memory oracleName,
        address member
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.addOracleMember.selector,
            oracleName,
            member
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        return messageId;
    }
    
    /**
     * @dev Remove a member from an oracle
     * @param oracleName The name of the oracle
     * @param member The address of the member to remove
     * @return messageId The ID of the message
     */
    function removeOracleMember(
        string memory oracleName,
        address member
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.removeOracleMember.selector,
            oracleName,
            member
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        return messageId;
    }
    
    /**
     * @dev Activate an oracle
     * @param oracleName The name of the oracle
     * @return messageId The ID of the message
     */
    function activateOracle(
        string memory oracleName
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.activateOracle.selector,
            oracleName
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        return messageId;
    }
    
    /**
     * @dev Deactivate an oracle
     * @param oracleName The name of the oracle
     * @return messageId The ID of the message
     */
    function deactivateOracle(
        string memory oracleName
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.deactivateOracle.selector,
            oracleName
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        return messageId;
    }
    
    /**
     * @dev Check if an oracle is active
     * @return active Whether the oracle is active
     */
    function isOracleActive(
        string memory /* oracleName */
    ) external pure returns (bool active) {
        // This is a view function that would ideally be implemented by having
        // a local cache of oracle statuses that gets updated via messages
        // For now, this is just a placeholder
        return true;
    }
    
    /**
     * @dev Vote on skill verification
     * @param applicant The address of the applicant
     * @param skillName The name of the skill
     * @param inFavor Whether to vote in favor of verification
     * @param reasonHash The reason for the vote
     * @return messageId The ID of the message
     */
    function voteOnSkillVerification(
        address applicant,
        string memory skillName,
        bool inFavor,
        string memory reasonHash
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.voteOnSkillVerification.selector,
            applicant,
            skillName,
            inFavor,
            reasonHash
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        return messageId;
    }
    
    /**
     * @dev Vote on a question
     * @param questionId The ID of the question
     * @param inFavor Whether to vote in favor of the question
     * @param reasonHash The reason for the vote
     * @return messageId The ID of the message
     */
    function voteOnQuestion(
        uint256 questionId,
        bool inFavor,
        string memory reasonHash
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.voteOnQuestion.selector,
            questionId,
            inFavor,
            reasonHash
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        return messageId;
    }
    
    /**
     * @dev Report a malicious member
     * @param oracleName The name of the oracle
     * @param member The address of the member
     * @param evidenceHash Hash of the evidence
     * @return messageId The ID of the message
     */
    function reportMaliciousMember(
        string memory oracleName,
        address member,
        string memory evidenceHash
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.reportMaliciousMember.selector,
            oracleName,
            member,
            evidenceHash
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        return messageId;
    }
    
    /**
     * @dev Request skill verification
     * @param skill The skill to verify
     * @param proofHash Hash of the proof
     * @return messageId The ID of the message
     */
    function requestSkillVerification(
        string memory skill,
        string memory proofHash
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.verifySkill.selector,
            msg.sender,
            skill,
            proofHash,
            msg.value // Fee amount
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        // Emit event
        emit SkillVerificationRequested(messageId, msg.sender, skill, proofHash);
        
        return messageId;
    }
    
    /**
     * @dev Claim disputed amount from a resolved dispute
     * @param disputeId The ID of the dispute
     * @return messageId The ID of the message
     */
    function claimDisputedAmount(
        uint256 disputeId
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.claimDisputedAmount.selector,
            disputeId,
            msg.value // Fee amount
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        // Emit event
        emit DisputedAmountClaimed(messageId, disputeId);
        
        return messageId;
    }
    
    /**
     * @dev Ask a question to Athena
     * @param question The question to ask
     * @param contextHash Hash of additional context for the question
     * @param oracleName Name of the oracle to use
     * @return messageId The ID of the message
     */
    function askAthena(
        string memory question,
        string memory contextHash,
        string memory oracleName
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Prepare the call data for the function on the Native Athena Contract
        bytes memory callData = abi.encodeWithSelector(
            INativeAthenaContract.askAthena.selector,
            question,
            contextHash,
            oracleName,
            msg.value // Fee amount
        );
        
        // Get the fee for the cross-chain message
        uint256 fee = IOpenWorkBridge(bridge).estimateFee(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Ensure enough ETH is provided to cover the fee
        require(msg.value >= fee, "Insufficient fee amount");
        
        // Send the cross-chain message
        messageId = IOpenWorkBridge(bridge).sendMessage{value: fee}(
            openWorkChainId,
            nativeAthenaContractAddress,
            callData
        );
        
        // Mark as processed
        messageProcessed[messageId] = true;
        
        // Emit event
        emit QuestionAsked(messageId, question, contextHash, oracleName);
        
        return messageId;
    }
    

    
    /**
     * @dev Withdraw ETH (for fees)
     */
    function withdrawETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    /**
     * @dev Receive function to accept ETH
     */
    receive() external payable {}
}
