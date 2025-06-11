// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IDisputeEngine.sol";
import "./interfaces/IOracleEngine.sol";
import "./interfaces/INativeOpenWorkContract.sol";
import "./interfaces/ISkillVerification.sol";
import "./interfaces/IQuestionEngine.sol";
import "./interfaces/INativeDAOGovernance.sol";
import "./interfaces/IGovernanceActionTracker.sol";
import "./interfaces/ICompleteSkillOracleManager.sol";
import "./libraries/AthenaOracles.sol";
import "./libraries/DisputeOracleStorage.sol";

// Minimal interface definition to avoid import problems
interface IOpenWorkDAO {
    function recordGovernanceAction(address member) external;
    function getVotingPower(address member) external view returns (uint256);
    function canVoteInGovernance(address member) external view returns (bool);
    function registerVerifiedSkill(
        uint256 userId, 
        uint256 skillId, 
        string memory skillName
    ) external returns (bool);
    
    // Token confiscation functions
    function requestConfiscation(address member) external returns (bool);
    function executeConfiscation(address member) external returns (bool);
}

/**
 * @title DisputeOracleEngine
 * @dev Contract for dispute resolution and oracle management in the OpenWork ecosystem
 */
contract DisputeOracleEngine is 
    Initializable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable,
    IDisputeEngine,
    IOracleEngine 
{
    // Use AthenaOracles library
    using AthenaOracles for AthenaOracles.SkillOracle;
    
    // Dispute status
    enum DisputeStatus { Created, UnderReview, InDeliberation, Resolved, Escalated }
    
    // Dispute data structure
    struct Dispute {
        uint256 id;
        uint256 jobId;
        address initiator;
        address respondent;
        string reason;
        DisputeStatus status;
        bool resultDetermined;
        bool fundsReleased;
        address recipient; // Address to receive funds when resolved
        uint256 lockedAmount; // Amount locked in dispute
        uint256 createdAt;
        uint256 resolvedAt;
        string evidence;
        string assignedOracle;      // Oracle handling this dispute
        uint256 requiredVotes;      // Minimum votes needed from oracle
        bool oracleValidated;       // Oracle meets requirements
    }
    
    // Fee structure
    struct FeeStructure {
        uint256 disputeFee;
        uint256 skillVerificationFee;
    }
    
    // Contract references
    INativeOpenWorkContract private _jobContract;
    IOpenWorkDAO private _daoContract;
    // Using SkillQuestionEngine for both skill verification and question engine functionality
    IQuestionEngine private _questionEngine;
    // Native DAO Governance for centralized governance action recording
    INativeDAOGovernance private _nativeDAOGovernance;
    // Governance Action Tracker for tracking governance actions
    IGovernanceActionTracker private _governanceActionTracker;
    // Skill Oracle Manager for oracle-specific dispute resolution
    ICompleteSkillOracleManager private _skillOracleManager;
    
    // Fee structure
    FeeStructure private _fees;
    
    // Voting period structure
    struct VotingPeriods {
        uint256 disputeVotingPeriod;
        uint256 skillVotingPeriod;
        uint256 questionVotingPeriod;
    }
    
    // Voting periods
    VotingPeriods private _votingPeriods;
    
    // Oracles
    struct SkillOracle {
        string name;
        string description;
        address[] members;
        bool isActive;
        uint256 createdAt;
        uint256 memberCount;
    }
    
    // Mapping from oracle name to oracle details
    mapping(string => SkillOracle) private _skillOracles;
    
    // Mapping from oracle name to member address to membership status
    mapping(string => mapping(address => bool)) private _oracleMembership;
    
    // Disputes mapping
    mapping(uint256 => Dispute) private _disputes;
    uint256 private _nextDisputeId;
    
    // Vote mappings for disputes
    mapping(uint256 => mapping(address => bool)) private _hasVotedOnDispute;
    mapping(uint256 => mapping(address => bool)) private _disputeVoteChoice;
    mapping(uint256 => uint256) private _disputeVotesFor;
    mapping(uint256 => uint256) private _disputeVotesAgainst;
    mapping(uint256 => string[]) private _disputeVoteReasons;
    
    // Malicious actors
    mapping(string => mapping(address => bool)) private _reportedMembers;
    
    // Events
    event DisputeCreated(uint256 indexed disputeId, uint256 indexed jobId, address initiator, address respondent, string reason);
    event DisputeStatusChanged(uint256 indexed disputeId, DisputeStatus newStatus);
    event DisputeResolved(uint256 indexed disputeId, address recipient, uint256 amount);
    event EvidenceSubmitted(uint256 indexed disputeId, address submitter, string evidence);
    event FeeUpdated(string feeType, uint256 newAmount);
    event DisputeEscalated(uint256 indexed disputeId, address escalator);
    event ContractReferenceUpdated(string contractType, address newAddress);
    event DisputedAmountClaimed(uint256 indexed disputeId, address recipient, uint256 amount);
    event DisputeFundsReleased(uint256 indexed disputeId, uint256 jobId, address recipient, uint256 amount);
    event OracleCreated(string name, string description);
    event OracleMemberAdded(string oracleName, address member);
    event OracleMemberRemoved(string oracleName, address member);
    event OracleActivated(string oracleName);
    event DisputeFeeRewarded(uint256 indexed disputeId, address voter, uint256 amount);
    event DisputeFeeRefunded(uint256 indexed disputeId, address initiator, uint256 amount);
    event MaliciousActorReported(string oracleName, address member, address reporter, string evidenceHash);
    event ConfiscationExecuted(address member);
    event OracleParameterUpdated(string oracleName, string paramName, uint256 oldValue, uint256 newValue);
    event ParameterUpdated(string paramName, uint256 oldValue, uint256 newValue);
    event DisputeVoteCast(uint256 indexed disputeId, address voter, bool inFavor, uint256 weight);
    event ContractAddressUpdated(string contractType, address newAddress);
    
    /**
     * @dev Initialize the contract
     * @param openWorkContract Address of the OpenWork Job Market contract
     * @param daoContract Address of the DAO Governance contract
     * @param questionEngineContract Address of the SkillQuestionEngine contract (optional)
     */
    /**
     * @dev Initialize function with simplified parameters
     * @param initialOwner The address that will become the owner of the contract
     */
    function initialize(
        address initialOwner
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // Transfer ownership to the initial owner if provided
        if (initialOwner != address(0)) {
            transferOwnership(initialOwner);
        }
        
        // Set default fees
        _fees.disputeFee = 0.01 ether;
        _fees.skillVerificationFee = 0.005 ether;
        
        // Set default voting periods
        _votingPeriods.disputeVotingPeriod = 4 days;
        _votingPeriods.skillVotingPeriod = 4 days;
        _votingPeriods.questionVotingPeriod = 4 days;
        
        _nextDisputeId = 1;
        
        // Create the default oracle
        SkillOracle storage defaultOracle = _skillOracles["DefaultOracle"];
        defaultOracle.name = "DefaultOracle";
        defaultOracle.description = "Default oracle for dispute resolution";
        defaultOracle.isActive = true; // For compatibility with existing code
        defaultOracle.createdAt = block.timestamp;
        
        emit OracleCreated("DefaultOracle", "Default oracle for dispute resolution");
    }
    
    /**
     * @dev Required by the UUPSUpgradeable module
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}
    
    // DISPUTE FUNCTIONS
    
    /**
     * @dev Raise a dispute for a job
     * @param jobId ID of the job in dispute
     * @param disputeHash IPFS hash containing dispute details
     * @param oracleName The name of the oracle to handle the dispute
     * @return disputeId ID of the created dispute
     */
    function raiseDispute(
        uint256 jobId,
        string calldata disputeHash,
        string calldata oracleName,
        uint256 /* fee */ // Commented out unused parameter
    ) external payable nonReentrant returns (uint256 disputeId) {
        // Verify the job exists
        require(_jobContract.jobExists(jobId), "Job does not exist");
        require(msg.value >= _fees.disputeFee, "Insufficient dispute fee");
        
        // Verify oracle is active
        require(isActive(oracleName), "Oracle is not active");
        
        // Get job details to identify parties
        (
            ,
            address client,
            ,
            ,
            ,
            ,
            ,
            address freelancer,
            ,
            
        ) = _jobContract.getJobPosting(jobId);
        
        // Verify the caller is either the client or freelancer
        require(msg.sender == client || msg.sender == freelancer, "Not authorized");
        
        // Determine the other party
        address initiator = msg.sender;
        address respondent = (initiator == client) ? freelancer : client;
        
        // Lock the funds for this job
        uint256 lockedAmount = _jobContract.lockDisputedFunds(jobId, _nextDisputeId);
        
        // Create dispute
        _disputes[_nextDisputeId] = Dispute({
            id: _nextDisputeId,
            jobId: jobId,
            initiator: initiator,
            respondent: respondent,
            reason: disputeHash,
            status: DisputeStatus.Created,
            resultDetermined: false,
            fundsReleased: false,
            recipient: address(0),
            lockedAmount: lockedAmount,
            createdAt: block.timestamp,
            resolvedAt: 0,
            evidence: "",
            assignedOracle: oracleName,
            requiredVotes: 3,
            oracleValidated: false
        });
        
        emit DisputeCreated(_nextDisputeId, jobId, initiator, respondent, disputeHash);
        
        disputeId = _nextDisputeId;
        _nextDisputeId++;
        
        return disputeId;
    }
    
    // Add the rest of the dispute functions here...
    // Add the oracle management functions here...
    
    /**
     * @dev Create a dispute (legacy function)
     */
    function createDispute(uint256 jobId, string memory reason, string memory oracleName) external payable nonReentrant returns (uint256) {
        // Direct implementation instead of calling raiseDispute to avoid function visibility issues
        // Verify the job exists
        require(_jobContract.jobExists(jobId), "Job does not exist");
        require(msg.value >= _fees.disputeFee, "Insufficient dispute fee");
        require(bytes(oracleName).length > 0, "Oracle name cannot be empty");
        
        // Validate the oracle if SkillOracleManager is set
        bool oracleValid = false;
        uint256 requiredVotes = 3; // Default minimum votes
        
        if (address(_skillOracleManager) != address(0)) {
            oracleValid = _skillOracleManager.validateOracleForDisputes(oracleName);
            require(oracleValid, "Oracle does not meet dispute resolution requirements");
            
            // Calculate required votes as percentage of oracle members
            uint256 memberCount = _skillOracleManager.getOracleMemberCount(oracleName);
            requiredVotes = (memberCount * 60) / 100; // 60% of oracle members
            if (requiredVotes < 3) requiredVotes = 3; // Minimum 3 votes
        }
        
        // Get job details to identify parties
        (
            ,
            address client,
            ,
            ,
            ,
            ,
            ,
            address freelancer,
            ,
            
        ) = _jobContract.getJobPosting(jobId);
        
        // Verify the caller is either the client or freelancer
        require(msg.sender == client || msg.sender == freelancer, "Not authorized");
        
        // Determine the other party
        address initiator = msg.sender;
        address respondent = (initiator == client) ? freelancer : client;
        
        // Lock the funds for this job
        uint256 lockedAmount = _jobContract.lockDisputedFunds(jobId, _nextDisputeId);
        
        // Create dispute
        _disputes[_nextDisputeId] = Dispute({
            id: _nextDisputeId,
            jobId: jobId,
            initiator: initiator,
            respondent: respondent,
            reason: reason,
            status: DisputeStatus.Created,
            resultDetermined: false,
            fundsReleased: false,
            recipient: address(0),
            lockedAmount: lockedAmount,
            createdAt: block.timestamp,
            resolvedAt: 0,
            evidence: "",
            assignedOracle: oracleName,
            requiredVotes: requiredVotes,
            oracleValidated: oracleValid
        });
        
        emit DisputeCreated(_nextDisputeId, jobId, initiator, respondent, reason);
        
        uint256 disputeId = _nextDisputeId;
        _nextDisputeId++;
        
        return disputeId;
    }

    /**
     * @dev Create a dispute with default general oracle (backward compatibility)
     */
    function createDispute(uint256 jobId, string memory reason) external payable nonReentrant returns (uint256) {
        // Use a default "General" oracle for backward compatibility
        return this.createDispute(jobId, reason, "General");
    }
    
    /**
     * @dev Submit evidence for a dispute
     */
    function submitEvidence(uint256 disputeId, string calldata evidenceHash) external returns (bool success) {
        Dispute storage dispute = _disputes[disputeId];
        require(dispute.id != 0, "Dispute does not exist");
        require(msg.sender == dispute.initiator || msg.sender == dispute.respondent, "Not authorized");
        require(dispute.status != DisputeStatus.Resolved, "Dispute already resolved");
        
        // Append evidence
        dispute.evidence = evidenceHash;
        
        emit EvidenceSubmitted(disputeId, msg.sender, evidenceHash);
        
        // Update status if needed
        if (dispute.status == DisputeStatus.Created) {
            dispute.status = DisputeStatus.UnderReview;
            emit DisputeStatusChanged(disputeId, DisputeStatus.UnderReview);
        }
        
        return true;
    }
    
    /**
     * @dev Vote on a dispute
     */
    function voteOnDispute(uint256 disputeId, bool inFavor, string calldata reasonHash) external returns (bool success) {
        Dispute storage dispute = _disputes[disputeId];
        require(dispute.id != 0, "Dispute does not exist");
        require(dispute.status != DisputeStatus.Resolved, "Dispute already resolved");
        require(!_hasVotedOnDispute[disputeId][msg.sender], "Already voted");
        require(dispute.oracleValidated, "Oracle not validated for disputes");
        
        // Check if voter is a valid oracle member
        bool isValidVoter = false;
        uint256 votingPower = 0;
        
        // Check if the voter is a member of the assigned oracle
        if (address(_skillOracleManager) != address(0)) {
            if (_skillOracleManager.isOracleMember(dispute.assignedOracle, msg.sender)) {
                isValidVoter = true;
                votingPower = _skillOracleManager.getOracleMemberVotingWeight(dispute.assignedOracle, msg.sender);
            }
        }
        
        // Fallback to DAO voting if oracle system not available
        if (!isValidVoter && address(_daoContract) != address(0)) {
            try _daoContract.getVotingPower(msg.sender) returns (uint256 vp) {
                if (vp > 0) {
                    isValidVoter = true;
                    votingPower = vp;
                }
            } catch {
                // If call fails, voting power remains 0
            }
        }
        
        require(isValidVoter && votingPower > 0, "Not authorized to vote on this dispute");
        
        // Mark the vote
        _hasVotedOnDispute[disputeId][msg.sender] = true;
        _disputeVoteChoice[disputeId][msg.sender] = inFavor;
        
        // Record the vote
        if (inFavor) {
            _disputeVotesFor[disputeId] += votingPower;
        } else {
            _disputeVotesAgainst[disputeId] += votingPower;
        }
        
        // Record the reason
        _disputeVoteReasons[disputeId].push(reasonHash);
        
        emit DisputeVoteCast(disputeId, msg.sender, inFavor, votingPower);
        
        // Update status if needed
        if (dispute.status == DisputeStatus.UnderReview) {
            dispute.status = DisputeStatus.InDeliberation;
            emit DisputeStatusChanged(disputeId, DisputeStatus.InDeliberation);
        }
        
        // Record governance action in both DAO contracts
        _recordGovernanceAction(msg.sender);
        
        return true;
    }
    
    /**
     * @dev Resolve a dispute
     */
    function resolveDispute(uint256 disputeId, address recipient) external returns (bool success) {
        Dispute storage dispute = _disputes[disputeId];
        require(dispute.id != 0, "Dispute does not exist");
        require(!dispute.resultDetermined, "Result already determined");
        require(recipient == dispute.initiator || recipient == dispute.respondent, "Invalid recipient");
        
        // Only owner or a user with sufficient voting power can resolve
        bool isAuthorized = false;
        
        if (msg.sender == owner()) {
            isAuthorized = true;
        } else if (address(_daoContract) != address(0)) {
            try _daoContract.canVoteInGovernance(msg.sender) returns (bool canVote) {
                isAuthorized = canVote;
            } catch {
                // If call fails, continue with default (not authorized)
            }
        }
        
        require(isAuthorized, "Not authorized to resolve");
        
        dispute.resultDetermined = true;
        dispute.recipient = recipient;
        dispute.status = DisputeStatus.Resolved;
        dispute.resolvedAt = block.timestamp;
        
        emit DisputeStatusChanged(disputeId, DisputeStatus.Resolved);
        emit DisputeResolved(disputeId, recipient, dispute.lockedAmount);
        
        return true;
    }
    
    /**
     * @dev Escalate a dispute
     */
    function escalateDispute(uint256 disputeId) external returns (bool success) {
        Dispute storage dispute = _disputes[disputeId];
        require(dispute.id != 0, "Dispute does not exist");
        require(dispute.status != DisputeStatus.Resolved, "Dispute already resolved");
        require(dispute.status != DisputeStatus.Escalated, "Dispute already escalated");
        
        // Only allow the parties involved in the dispute to escalate
        require(msg.sender == dispute.initiator || msg.sender == dispute.respondent, "Not authorized");
        
        dispute.status = DisputeStatus.Escalated;
        
        emit DisputeStatusChanged(disputeId, DisputeStatus.Escalated);
        emit DisputeEscalated(disputeId, msg.sender);
        
        return true;
    }
    
    /**
     * @dev Claim disputed amount after resolution
     */
    function claimDisputedAmount(uint256 disputeId) external nonReentrant returns (uint256 amount) {
        Dispute storage dispute = _disputes[disputeId];
        require(dispute.id != 0, "Dispute does not exist");
        
        require(dispute.resultDetermined, "Result not determined");
        require(!dispute.fundsReleased, "Funds already released");
        
        address recipient = dispute.recipient;
        amount = dispute.lockedAmount;
        
        // Release the disputed funds to the appropriate recipient
        _jobContract.releaseDisputedFunds(
            dispute.jobId, 
            disputeId, 
            uint256(uint160(recipient)), // convert address to uint256
            uint256(0), // loser address converted to uint256 (not used in this context)
            amount, 
            0 // platform fee (not used in this context)
        );
        
        dispute.fundsReleased = true;
        
        emit DisputedAmountClaimed(disputeId, recipient, amount);
        emit DisputeFundsReleased(disputeId, dispute.jobId, recipient, amount);
        
        return amount;
    }
    
    /**
     * @dev Check if a user is a party in a dispute
     */
    function checkDisputeParticipation(uint256 disputeId, address voter) external view returns (bool isInitiator, bool isRespondent) {
        Dispute storage dispute = _disputes[disputeId];
        if (dispute.id == 0) {
            return (false, false);
        }
        
        return (voter == dispute.initiator, voter == dispute.respondent);
    }
    
    /**
     * @dev Get dispute votes
     */
    function getDisputeVotes(uint256 disputeId) external view returns (uint256 votesFor, uint256 votesAgainst) {
        return (_disputeVotesFor[disputeId], _disputeVotesAgainst[disputeId]);
    }
    
    /**
     * @dev Get dispute details
     */
    function getDisputeDetails(uint256 disputeId) external view returns (
        DisputeStorage.Dispute memory dispute,
        uint256 votesFor,
        uint256 votesAgainst
    ) {
        Dispute storage d = _disputes[disputeId];
        
        DisputeStorage.Dispute memory result;
        result.id = d.id;
        result.jobId = d.jobId;
        result.initiator = d.initiator;
        result.respondent = d.respondent;
        result.reason = d.reason;
        result.status = DisputeStorage.DisputeStatus(uint8(d.status));
        result.resultDetermined = d.resultDetermined;
        result.fundsReleased = d.fundsReleased;
        result.recipient = d.recipient;
        result.lockedAmount = d.lockedAmount;
        result.createdAt = d.createdAt;
        result.resolvedAt = d.resolvedAt;
        result.evidence = d.evidence;
        
        return (result, _disputeVotesFor[disputeId], _disputeVotesAgainst[disputeId]);
    }
    
    /**
     * @dev Get dispute status
     */
    function getDisputeStatus(uint256 disputeId) external view returns (DisputeStorage.DisputeStatus status) {
        Dispute storage d = _disputes[disputeId];
        if (d.id == 0) {
            return DisputeStorage.DisputeStatus.Created; // Default value
        }
        
        return DisputeStorage.DisputeStatus(uint8(d.status));
    }
    
    /**
     * @dev Claim dispute fee refund
     */
    function claimDisputeFeeRefund(uint256 disputeId) external nonReentrant returns (uint256 amount) {
        Dispute storage dispute = _disputes[disputeId];
        require(dispute.id != 0, "Dispute does not exist");
        require(dispute.resultDetermined, "Dispute not resolved");
        require(msg.sender == dispute.initiator, "Not the initiator");
        
        if (dispute.recipient == dispute.initiator) {
            // Initiator won, refund the dispute fee
            amount = _fees.disputeFee;
            payable(msg.sender).transfer(amount);
            emit DisputeFeeRefunded(disputeId, msg.sender, amount);
        }
        
        return amount;
    }
    
    /**
     * @dev Claim dispute fee reward
     */
    function claimDisputeFeeReward(uint256 disputeId) external nonReentrant returns (uint256 amount) {
        Dispute storage dispute = _disputes[disputeId];
        require(dispute.id != 0, "Dispute does not exist");
        require(dispute.resultDetermined, "Dispute not resolved");
        require(_hasVotedOnDispute[disputeId][msg.sender], "Did not vote");
        
        bool votedForWinner = _disputeVoteChoice[disputeId][msg.sender] == (dispute.recipient == dispute.initiator);
        
        if (votedForWinner) {
            // Voter voted for the winner, reward with a portion of the fee
            uint256 totalVotes = _disputeVotesFor[disputeId] + _disputeVotesAgainst[disputeId];
            if (totalVotes > 0) {
                uint256 voterVotes = 1; // Default
                if (address(_daoContract) != address(0)) {
                    try _daoContract.getVotingPower(msg.sender) returns (uint256 vp) {
                        if (vp > 0) {
                            voterVotes = vp;
                        }
                    } catch {
                        // If call fails, continue with default
                    }
                }
                
                amount = (_fees.disputeFee * voterVotes) / totalVotes;
                if (amount > 0) {
                    payable(msg.sender).transfer(amount);
                    emit DisputeFeeRewarded(disputeId, msg.sender, amount);
                }
            }
        }
        
        return amount;
    }
    
    // ORACLE FUNCTIONS
    
    /**
     * @dev Create a new oracle
     */
    function createOracle(string calldata name, string calldata description) external returns (bool success) {
        require(msg.sender == owner(), "Only owner can create oracles");
        require(bytes(_skillOracles[name].name).length == 0, "Oracle already exists");
        
        SkillOracle storage oracle = _skillOracles[name];
        oracle.name = name;
        oracle.description = description;
        oracle.isActive = false; // Inactive by default until members are added
        oracle.createdAt = block.timestamp;
        
        emit OracleCreated(name, description);
        
        return true;
    }
    
    /**
     * @dev Add a member to an oracle
     */
    function addOracleMember(string calldata oracleName, address member) external returns (bool success) {
        require(msg.sender == owner(), "Only owner can add members");
        require(bytes(_skillOracles[oracleName].name).length > 0, "Oracle does not exist");
        require(!_oracleMembership[oracleName][member], "Already a member");
        
        SkillOracle storage oracle = _skillOracles[oracleName];
        oracle.members.push(member);
        oracle.memberCount++;
        _oracleMembership[oracleName][member] = true;
        
        emit OracleMemberAdded(oracleName, member);
        
        return true;
    }
    
    /**
     * @dev Remove a member from an oracle
     */
    function removeOracleMember(string calldata oracleName, address member) external returns (bool success) {
        require(msg.sender == owner(), "Only owner can remove members");
        require(bytes(_skillOracles[oracleName].name).length > 0, "Oracle does not exist");
        require(_oracleMembership[oracleName][member], "Not a member");
        
        _oracleMembership[oracleName][member] = false;
        
        SkillOracle storage oracle = _skillOracles[oracleName];
        for (uint256 i = 0; i < oracle.members.length; i++) {
            if (oracle.members[i] == member) {
                // Swap with the last element and pop
                if (i < oracle.members.length - 1) {
                    oracle.members[i] = oracle.members[oracle.members.length - 1];
                }
                oracle.members.pop();
                break;
            }
        }
        
        oracle.memberCount--;
        
        emit OracleMemberRemoved(oracleName, member);
        
        return true;
    }
    
    /**
     * @dev Activate an oracle
     */
    function activateOracle(string calldata oracleName) external returns (bool success) {
        require(msg.sender == owner(), "Only owner can activate oracles");
        require(bytes(_skillOracles[oracleName].name).length > 0, "Oracle does not exist");
        
        SkillOracle storage oracle = _skillOracles[oracleName];
        oracle.isActive = true;
        
        emit OracleActivated(oracleName);
        
        return true;
    }
    
    /**
     * @dev Deactivate an oracle
     */
    function deactivateOracle(string calldata oracleName) external returns (bool success) {
        require(msg.sender == owner(), "Only owner can deactivate oracles");
        require(bytes(_skillOracles[oracleName].name).length > 0, "Oracle does not exist");
        
        SkillOracle storage oracle = _skillOracles[oracleName];
        oracle.isActive = false;
        
        emit OracleActivated(oracleName);
        
        return true;
    }
    
    /**
     * @dev Check if an address is an oracle member
     */
    function isOracleMember(string calldata oracleName, address member) public view returns (bool isMember) {
        return _oracleMembership[oracleName][member];
    }
    
    /**
     * @dev Check if an oracle is active
     */
    function isActive(string calldata oracleName) public view returns (bool) {
        return _skillOracles[oracleName].isActive;
    }
    
    /**
     * @dev Get oracle details
     */
    function getOracleDetails(string calldata oracleName) external view returns (
        string memory name,
        string memory description,
        address[] memory members,
        bool active,
        uint256 createdAt,
        uint256 memberCount
    ) {
        SkillOracle storage oracle = _skillOracles[oracleName];
        
        return (
            oracle.name,
            oracle.description,
            oracle.members,
            oracle.isActive,
            oracle.createdAt,
            oracle.memberCount
        );
    }
    
    /**
     * @dev Report a malicious member in an oracle
     */
    function reportMaliciousMember(
        string calldata oracleName,
        address member,
        string calldata evidenceHash
    ) external returns (bool success) {
        require(bytes(_skillOracles[oracleName].name).length > 0, "Oracle does not exist");
        require(_oracleMembership[oracleName][member], "Not an oracle member");
        
        // Check if reporter is an oracle member or DAO member
        bool isValidReporter = _oracleMembership[oracleName][msg.sender];
        
        if (!isValidReporter && address(_daoContract) != address(0)) {
            try _daoContract.canVoteInGovernance(msg.sender) returns (bool canVote) {
                isValidReporter = canVote;
            } catch {
                // If call fails, continue with default (not valid)
            }
        }
        
        require(isValidReporter, "Not authorized to report");
        
        _reportedMembers[oracleName][member] = true;
        
        emit MaliciousActorReported(oracleName, member, msg.sender, evidenceHash);
        
        // Try to request confiscation through DAO
        if (address(_daoContract) != address(0)) {
            try _daoContract.requestConfiscation(member) returns (bool requested) {
                if (requested) {
                    // Confiscation request submitted
                }
            } catch {
                // Continue even if request fails
            }
        }
        
        return true;
    }
    
    /**
     * @dev Check if a member is reported in an oracle
     */
    function isReportedInOracle(string calldata oracleName, address member) external view returns (bool reported) {
        return _reportedMembers[oracleName][member];
    }
    
    // ADMIN FUNCTIONS
    
    /**
     * @dev Set the dispute fee
     */
    function updateDisputeFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = _fees.disputeFee;
        _fees.disputeFee = newFee;
        
        emit FeeUpdated("DisputeFee", newFee);
        emit ParameterUpdated("DisputeFee", oldFee, newFee);
    }
    
    /**
     * @dev Set the dispute voting period
     */
    function updateDisputeVotingPeriod(uint256 newPeriod) external onlyOwner {
        uint256 oldPeriod = _votingPeriods.disputeVotingPeriod;
        _votingPeriods.disputeVotingPeriod = newPeriod;
        
        emit ParameterUpdated("DisputeVotingPeriod", oldPeriod, newPeriod);
    }
    
    /**
     * @dev Set the question engine contract reference
     */
    function setQuestionEngineContract(address newContract) external onlyOwner {
        require(newContract != address(0), "Invalid question engine contract address");
        _questionEngine = IQuestionEngine(newContract);
        
        emit ContractReferenceUpdated("QuestionEngine", newContract);
    }
    
    /**
     * @dev Set the job contract reference
     */
    function setJobContract(address newContract) external onlyOwner {
        require(newContract != address(0), "Invalid job contract address");
        _jobContract = INativeOpenWorkContract(newContract);
        
        emit ContractReferenceUpdated("JobContract", newContract);
    }
    
    /**
     * @dev Set the DAO contract reference
     */
    function setDAOContract(address newContract) external onlyOwner {
        require(newContract != address(0), "Invalid DAO contract address");
        _daoContract = IOpenWorkDAO(newContract);
        
        emit ContractReferenceUpdated("DAOContract", newContract);
    }
    
    /**
     * @dev Set the Native DAO Governance contract address
     * @param newContract The address of the new Native DAO Governance contract
     */
    function setNativeDAOGovernanceContract(address newContract) external onlyOwner {
        require(newContract != address(0), "Invalid Native DAO Governance address");
        _nativeDAOGovernance = INativeDAOGovernance(newContract);
        
        emit ContractReferenceUpdated("NativeDAOGovernance", newContract);
    }
    
    /**
     * @dev Set the Governance Action Tracker contract
     * @param newContract Address of the new Governance Action Tracker contract
     */
    function setGovernanceActionTracker(address newContract) external onlyOwner {
        require(newContract != address(0), "Invalid Governance Action Tracker address");
        _governanceActionTracker = IGovernanceActionTracker(newContract);
        
        emit ContractReferenceUpdated("GovernanceActionTracker", newContract);
    }
    
    /**
     * @dev Helper function to record governance actions in both DAO contracts
     * @param user The address of the user performing the governance action
     */
    function _recordGovernanceAction(address user) internal {
        // First try the new GovernanceActionTracker
        if (address(_governanceActionTracker) != address(0)) {
            try _governanceActionTracker.recordGovernanceAction(user) {
                // Action recorded successfully in GovernanceActionTracker
                // No need to record in other contracts as GovernanceActionTracker is now the centralized source
                return;
            } catch {
                // Continue with legacy methods if recording fails
            }
        }
        
        // If GovernanceActionTracker is not set, try the centralized Native DAO Governance
        if (address(_nativeDAOGovernance) != address(0)) {
            try _nativeDAOGovernance.recordGovernanceAction(user) {
                // Action recorded successfully in centralized governance
            } catch {
                // Continue even if recording fails
            }
        }
        
        // Also try the original DAO contract for backward compatibility
        if (address(_daoContract) != address(0)) {
            try _daoContract.recordGovernanceAction(user) {
                // Action recorded successfully in original DAO
            } catch {
                // Continue even if recording fails
            }
        }
    }
    
    /**
     * @dev Execute confiscation of tokens from a malicious actor
     */
    function executeConfiscation(address member) external returns (bool success) {
        require(msg.sender == owner(), "Only owner can execute confiscation");
        
        if (address(_daoContract) != address(0)) {
            try _daoContract.executeConfiscation(member) returns (bool executed) {
                if (executed) {
                    emit ConfiscationExecuted(member);
                    return true;
                }
            } catch {
                // Continue even if execution fails
            }
        }
        
        return false;
    }
    
    /**
     * @dev Sets the address of the SkillQuestionEngine contract
     * @param skillQuestionEngineAddress The address of the SkillQuestionEngine contract
     */
    function setSkillQuestionEngine(address skillQuestionEngineAddress) external onlyOwner {
        require(skillQuestionEngineAddress != address(0), "Invalid address");
        _questionEngine = IQuestionEngine(skillQuestionEngineAddress);
        emit ContractReferenceUpdated("SkillQuestionEngine", skillQuestionEngineAddress);
    }
    
    /**
     * @dev Gets the address of the SkillQuestionEngine contract
     * @return The address of the SkillQuestionEngine contract
     */
    function getSkillQuestionEngine() external view returns (address) {
        return address(_questionEngine);
    }
    
    /**
     * @dev Set the SkillOracleManager contract reference
     * @param skillOracleManagerAddress Address of the SkillOracleManager contract
     */
    function setSkillOracleManager(address skillOracleManagerAddress) external onlyOwner {
        require(skillOracleManagerAddress != address(0), "Invalid address");
        _skillOracleManager = ICompleteSkillOracleManager(skillOracleManagerAddress);
        emit ContractReferenceUpdated("SkillOracleManager", skillOracleManagerAddress);
    }
    
    /**
     * @dev Getter for dispute count
     * @return The total number of disputes created
     */
    function getDisputeCount() external view returns (uint256) {
        return _nextDisputeId - 1;
    }
}

