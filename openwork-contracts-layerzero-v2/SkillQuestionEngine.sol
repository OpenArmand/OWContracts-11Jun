// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IDisputeEngine.sol";
import "./interfaces/IOracleEngine.sol";
import "./interfaces/ISkillVerification.sol";
import "./interfaces/IQuestionEngine.sol";
import "./interfaces/ISkillOracleManager.sol"; 
import "./interfaces/ICompleteSkillOracleManager.sol";
import "./interfaces/INativeDAOGovernance.sol";
import "./interfaces/IGovernanceActionTracker.sol";
import "./libraries/SkillQuestionStorage.sol";

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
}

/**
 * @title OracleEngineAdapter
 * @dev Adapter for the SkillOracleManager to be used as an IOracleEngine
 */
contract OracleEngineAdapter is IOracleEngine {
    ICompleteSkillOracleManager private _skillOracleManager;

    constructor(address skillOracleManagerAddress) {
        _skillOracleManager = ICompleteSkillOracleManager(skillOracleManagerAddress);
    }

    // Implement IOracleEngine methods using SkillOracleManager
    function createOracle(string calldata name, string calldata description) external returns (bool success) {
        // In SkillOracleManager, oracle name = skill name, so register skill with name as both skill name and oracle name
        return _skillOracleManager.registerSkill(name, description, 0);
    }

    function addOracleMember(string calldata oracleName, address member) external returns (bool success) {
        // Default stake amount of 1 - this would need to be adjusted based on requirements
        return _skillOracleManager.addOracleMember(oracleName, member, 1);
    }

    function removeOracleMember(string calldata oracleName, address member) external returns (bool success) {
        return _skillOracleManager.removeOracleMember(oracleName, member);
    }

    function activateOracle(string calldata oracleName) external returns (bool success) {
        return _skillOracleManager.setOracleActive(oracleName, true);
    }

    function deactivateOracle(string calldata oracleName) external returns (bool success) {
        return _skillOracleManager.setOracleActive(oracleName, false);
    }

    function isOracleMember(string calldata oracleName, address member) external view returns (bool isMember) {
        return _skillOracleManager.isOracleMember(oracleName, member);
    }

    function isActive(string calldata oracleName) external view returns (bool) {
        return _skillOracleManager.isOracleActive(oracleName);
    }

    function getOracleDetails(string calldata oracleName) external view returns (
        string memory name,
        string memory description,
        address[] memory members,
        bool active,
        uint256 createdAt,
        uint256 memberCount
    ) {
        // Since SkillOracleManager doesn't provide all these details in a single call,
        // we build a response with available data
        bool isOracleActive = _skillOracleManager.isOracleActive(oracleName);
        uint256 count = _skillOracleManager.getOracleMemberCount(oracleName);
        string memory ipfsHash = _skillOracleManager.getSkillIpfsHash(oracleName);

        // Return partially populated data (members array is empty as SkillOracleManager doesn't expose this)
        return (
            oracleName,
            ipfsHash,
            new address[](0), // Cannot retrieve member list from SkillOracleManager
            isOracleActive,
            0, // Creation date not available
            count
        );
    }

    function reportMaliciousMember(
        string calldata oracleName,
        address member,
        string calldata /* evidenceHash */
    ) external returns (bool success) {
        // Not directly supported in SkillOracleManager
        // Could implement by removing stake as a penalty
        _skillOracleManager.removeStake(oracleName, member, 1);
        return true;
    }

    function isReportedInOracle(string calldata /* oracleName */, address /* member */) external pure returns (bool) {
        // Not directly supported in SkillOracleManager
        return false;
    }
}

/**
 * @title SkillQuestionEngine
 * @dev Contract for skill verification and Q&A functionality in the OpenWork ecosystem
 */
contract SkillQuestionEngine is 
    Initializable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable,
    ISkillVerification,
    IQuestionEngine 
{
    // Contract references
    IDisputeEngine private _disputeEngine;
    IOracleEngine private _oracleEngine;
    IOpenWorkDAO private _daoContract;
    ICompleteSkillOracleManager private _skillOracleManager;
    // Native DAO Governance for centralized governance action recording
    INativeDAOGovernance private _nativeDAOGovernance;
    // Governance Action Tracker for centralized action recording
    IGovernanceActionTracker private _governanceActionTracker;

    // Fee structure
    struct FeeStructure {
        uint256 skillVerificationFee;
        uint256 questionFee;
    }

    // Fees
    FeeStructure private _fees;

    // Voting period structure
    struct VotingPeriods {
        uint256 skillVotingPeriod;
        uint256 questionVotingPeriod;
    }

    // Voting periods
    VotingPeriods private _votingPeriods;

    // SKILL VERIFICATION

    // Mapping of user address to skill name to verification status
    mapping(address => mapping(string => bool)) private _verifiedSkills;

    // Mapping of user address to skill name to application ID
    mapping(address => mapping(string => uint256)) private _skillApplicationIds;

    // Mapping of application ID to application details
    mapping(uint256 => SkillStorage.SkillApplication) private _skillApplications;

    // Next application ID
    uint256 private _nextSkillApplicationId;

    // Mapping of application ID to votes
    mapping(uint256 => mapping(address => bool)) private _hasVotedOnSkill;
    mapping(uint256 => mapping(address => bool)) private _skillVoteChoice;
    mapping(uint256 => uint256) private _skillVotesFor;
    mapping(uint256 => uint256) private _skillVotesAgainst;
    mapping(uint256 => string[]) private _skillVoteReasons;

    // QUESTIONS

    // Mapping of question ID to question details
    mapping(uint256 => QuestionStorage.Question) private _questions;

    // Next question ID
    uint256 private _nextQuestionId;

    // Mapping of question ID to votes
    mapping(uint256 => mapping(address => bool)) private _hasVotedOnQuestion;
    mapping(uint256 => mapping(address => bool)) private _questionVoteChoice;
    mapping(uint256 => uint256) private _questionVotesFor;
    mapping(uint256 => uint256) private _questionVotesAgainst;
    mapping(uint256 => string[]) private _questionVoteReasons;

    // Events
    event SkillApplicationCreated(uint256 applicationId, address applicant, string skillName, string evidence, string oracleName);
    event SkillVerified(address applicant, string skillName, uint256 applicationId);
    event SkillRejected(address applicant, string skillName, uint256 applicationId);
    event SkillVoteCast(uint256 applicationId, address voter, bool inFavor, string reason);
    event QuestionAsked(uint256 questionId, address asker, string questionHash, string oracleName);
    event QuestionVoteCast(uint256 questionId, address voter, bool inFavor, string reason);
    event QuestionAnswered(uint256 questionId, string answerHash);
    event ContractReferenceUpdated(string contractType, address newAddress);
    event ParameterUpdated(string paramName, uint256 oldValue, uint256 newValue);
    event FeeUpdated(string feeType, uint256 newAmount);

    // Modifiers
    modifier onlyDisputeEngine() {
        require(msg.sender == address(_disputeEngine), "Only DisputeEngine can call");
        _;
    }

    /**
     * @dev Initialize the contract with only the initial owner
     * @param initialOwner Address of the initial owner
     */
    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Set default fees
        _fees.skillVerificationFee = 0.005 ether;
        _fees.questionFee = 0.002 ether;

        // Set default voting periods
        _votingPeriods.skillVotingPeriod = 4 days;
        _votingPeriods.questionVotingPeriod = 4 days;

        _nextSkillApplicationId = 1;
        _nextQuestionId = 1;
    }



    /**
     * @dev Update the oracle engine reference
     * @param oracleEngineAddress New oracle engine address
     */
    function updateOracleEngine(address oracleEngineAddress) external onlyOwner {
        require(oracleEngineAddress != address(0), "Invalid address");
        _oracleEngine = IOracleEngine(oracleEngineAddress);
        emit ContractReferenceUpdated("OracleEngine", oracleEngineAddress);
    }

    /**
     * @dev Update the skill oracle manager reference
     * @param skillOracleManagerAddress New skill oracle manager address
     */
    function updateSkillOracleManager(address skillOracleManagerAddress) external onlyOwner {
        require(skillOracleManagerAddress != address(0), "Invalid address");
        _skillOracleManager = ICompleteSkillOracleManager(skillOracleManagerAddress);

        // Deploy a new adapter for the updated SkillOracleManager
        OracleEngineAdapter adapter = new OracleEngineAdapter(skillOracleManagerAddress);
        _oracleEngine = adapter;

        emit ContractReferenceUpdated("SkillOracleManager", skillOracleManagerAddress);
    }

    // SKILL VERIFICATION FUNCTIONS

    /**
     * @dev Request skill verification (alias for backwards compatibility)
     */
    function requestSkillVerification(
        string calldata skillName,
        string calldata oracleName,
        string calldata evidenceHash
    ) external payable returns (bool) {
        applyForSkillVerification(skillName, oracleName, evidenceHash);
        return true;
    }

    /**
     * @dev Apply for skill verification
     */
    function applyForSkillVerification(
        string calldata skillName,
        string calldata oracleName,
        string calldata evidenceHash
    ) public payable nonReentrant returns (uint256 applicationId) {
        require(msg.value >= _fees.skillVerificationFee, "Insufficient fee");
        require(_oracleEngine.isActive(oracleName), "Oracle not active");
        require(!_verifiedSkills[msg.sender][skillName], "Skill already verified");

        // Create a new skill application
        applicationId = _nextSkillApplicationId++;

        _skillApplications[applicationId] = SkillStorage.SkillApplication({
            id: applicationId,
            applicant: msg.sender,
            skillName: skillName,
            evidence: evidenceHash,
            oracleName: oracleName,
            status: SkillStorage.SkillStatus.Applied,
            createdAt: block.timestamp,
            verifiedAt: 0
        });

        // Map the applicant and skill to the application
        _skillApplicationIds[msg.sender][skillName] = applicationId;

        emit SkillApplicationCreated(applicationId, msg.sender, skillName, evidenceHash, oracleName);

        return applicationId;
    }

    /**
     * @dev Vote on a skill verification application
     */
  function voteOnSkillApplication(
    uint256 applicationId,
    bool inFavor,
    string calldata reasonHash
) external returns (bool) {
    SkillStorage.SkillApplication storage application = _skillApplications[applicationId];
    require(application.id != 0, "Application does not exist");
    require(application.status == SkillStorage.SkillStatus.Applied, "Not in applied state");
    require(!_hasVotedOnSkill[applicationId][msg.sender], "Already voted");

    // Verify the voter is part of the oracle
    string memory oracleName = application.oracleName;
    require(_oracleEngine.isOracleMember(oracleName, msg.sender), "Not an oracle member");

    // Record the vote
    _hasVotedOnSkill[applicationId][msg.sender] = true;
    _skillVoteChoice[applicationId][msg.sender] = inFavor;

    if (inFavor) {
        _skillVotesFor[applicationId]++;
    } else {
        _skillVotesAgainst[applicationId]++;
    }

    _skillVoteReasons[applicationId].push(reasonHash);

    emit SkillVoteCast(applicationId, msg.sender, inFavor, reasonHash);

    // Check if there are enough votes to make a decision
    uint256 totalVotes = _skillVotesFor[applicationId] + _skillVotesAgainst[applicationId];

    // If more than half of the oracle members have voted, make a decision
    if (_oracleEngine.isActive(oracleName)) {
        (,,,,,uint256 memberCount) = _oracleEngine.getOracleDetails(oracleName);

        if (totalVotes >= (memberCount / 2) + 1) {
            if (_skillVotesFor[applicationId] > _skillVotesAgainst[applicationId]) {
                _verifySkill(application.applicant, application.skillName, applicationId);
            } else {
                _rejectSkill(application.applicant, application.skillName, applicationId);
            }
        }
    }

    // Record governance action in both DAO contracts
    _recordGovernanceAction(msg.sender);

    return true;
}


    /**
     * @dev Vote on a skill verification (alternative interface for compatibility)
     * @notice This function must be placed after voteOnSkillApplication
     */
   function voteOnSkillVerification(
    address applicant,
    string calldata skillName,
    bool inFavor,
    string calldata reasonHash
) external returns (bool) {
    uint256 applicationId = _skillApplicationIds[applicant][skillName];
    require(applicationId != 0, "No application found");

    // Implement the logic here instead of calling voteOnSkillApplication
    SkillStorage.SkillApplication storage application = _skillApplications[applicationId];
    require(application.id != 0, "Application does not exist");
    require(application.status == SkillStorage.SkillStatus.Applied, "Not in applied state");
    require(!_hasVotedOnSkill[applicationId][msg.sender], "Already voted");

    // Verify the voter is part of the oracle
    string memory oracleName = application.oracleName;
    require(_oracleEngine.isOracleMember(oracleName, msg.sender), "Not an oracle member");

    // Record the vote
    _hasVotedOnSkill[applicationId][msg.sender] = true;
    _skillVoteChoice[applicationId][msg.sender] = inFavor;

    if (inFavor) {
        _skillVotesFor[applicationId]++;
    } else {
        _skillVotesAgainst[applicationId]++;
    }

    _skillVoteReasons[applicationId].push(reasonHash);

    emit SkillVoteCast(applicationId, msg.sender, inFavor, reasonHash);

    // Check if there are enough votes to make a decision
    uint256 totalVotes = _skillVotesFor[applicationId] + _skillVotesAgainst[applicationId];

    // If more than half of the oracle members have voted, make a decision
    if (_oracleEngine.isActive(oracleName)) {
        (,,,,,uint256 memberCount) = _oracleEngine.getOracleDetails(oracleName);

        if (totalVotes >= (memberCount / 2) + 1) {
            if (_skillVotesFor[applicationId] > _skillVotesAgainst[applicationId]) {
                _verifySkill(application.applicant, application.skillName, applicationId);
            } else {
                _rejectSkill(application.applicant, application.skillName, applicationId);
            }
        }
    }

    // Record governance action in both DAO contracts
    _recordGovernanceAction(msg.sender);

    return true;
}

    /**
     * @dev Internal function to mark a skill as verified
     */
    function _verifySkill(address applicant, string memory skillName, uint256 applicationId) internal {
        _verifiedSkills[applicant][skillName] = true;

        SkillStorage.SkillApplication storage application = _skillApplications[applicationId];
        application.status = SkillStorage.SkillStatus.Verified;
        application.verifiedAt = block.timestamp;

        emit SkillVerified(applicant, skillName, applicationId);

        // Register the skill in the SkillOracleManager if it's configured
        if (address(_skillOracleManager) != address(0)) {
            try _skillOracleManager.verifyUserSkill(applicant, skillName) {
                // Skill registered in SkillOracleManager successfully
            } catch {
                // Continue even if registration fails
            }
        }

        // Register the skill in the DAO if possible
        if (address(_daoContract) != address(0)) {
            try _daoContract.registerVerifiedSkill(
                uint256(uint160(applicant)), // userId (convert address to uint256)
                applicationId, // skillId
                skillName
            ) {
                // Skill registered successfully
            } catch {
                // Continue even if registration fails
            }
        }
    }

    /**
     * @dev Internal function to mark a skill as rejected
     */
    function _rejectSkill(address applicant, string memory skillName, uint256 applicationId) internal {
        SkillStorage.SkillApplication storage application = _skillApplications[applicationId];
        application.status = SkillStorage.SkillStatus.Rejected;

        emit SkillRejected(applicant, skillName, applicationId);
    }

    /**
     * @dev Externally verifies a skill (admin only)
     */
    function verifySkill(address applicant, string calldata skillName) external returns (bool) {
        require(msg.sender == owner(), "Only owner can verify directly");

        uint256 applicationId = _skillApplicationIds[applicant][skillName];
        if (applicationId == 0) {
            // Create a synthetic application if none exists
            applicationId = _nextSkillApplicationId++;

            _skillApplications[applicationId] = SkillStorage.SkillApplication({
                id: applicationId,
                applicant: applicant,
                skillName: skillName,
                evidence: "",
                oracleName: "DefaultOracle",
                status: SkillStorage.SkillStatus.Applied,
                createdAt: block.timestamp,
                verifiedAt: 0
            });

            _skillApplicationIds[applicant][skillName] = applicationId;
        }

        _verifySkill(applicant, skillName, applicationId);
        return true;
    }

    /**
     * @dev Check if a skill is verified
     */
    function isSkillVerified(address applicant, string calldata skillName) external view returns (bool) {
        // First check our internal verification status
        bool verifiedLocally = _verifiedSkills[applicant][skillName];

        // If not verified locally but we have SkillOracleManager, check there too
        if (!verifiedLocally && address(_skillOracleManager) != address(0)) {
            try _skillOracleManager.hasUserSkill(applicant, skillName) returns (bool hasSkill) {
                return hasSkill;
            } catch {
                // If the call fails, just return our local verification status
                return verifiedLocally;
            }
        }

        return verifiedLocally;
    }

    /**
     * @dev Get skill verification status
     */
    function getSkillVerificationStatus(
        address applicant, 
        string calldata skillName
    ) external view returns (
        SkillStorage.SkillApplication memory application,
        bool verified
    ) {
        uint256 applicationId = _skillApplicationIds[applicant][skillName];
        if (applicationId == 0) {
            // Return an empty application if none exists
            return (
                SkillStorage.SkillApplication({
                    id: 0,
                    applicant: address(0),
                    skillName: "",
                    evidence: "",
                    oracleName: "",
                    status: SkillStorage.SkillStatus.Applied,
                    createdAt: 0,
                    verifiedAt: 0
                }),
                false
            );
        }

        return (_skillApplications[applicationId], _verifiedSkills[applicant][skillName]);
    }

    /**
     * @dev Get skill application details
     */
    function getSkillApplicationDetails(
        uint256 applicationId
    ) external view returns (SkillStorage.SkillApplication memory) {
        return _skillApplications[applicationId];
    }

    /**
     * @dev Claim skill verification fee reward
     */
    function claimSkillVerificationFeeReward(
        address applicant,
        string calldata skillName
    ) external nonReentrant returns (uint256 amount) {
        uint256 applicationId = _skillApplicationIds[applicant][skillName];
        require(applicationId != 0, "No application found");

        SkillStorage.SkillApplication storage application = _skillApplications[applicationId];
        require(
            application.status == SkillStorage.SkillStatus.Verified || 
            application.status == SkillStorage.SkillStatus.Rejected, 
            "Application not resolved"
        );

        require(_hasVotedOnSkill[applicationId][msg.sender], "Did not vote");

        bool votedCorrectly = _skillVoteChoice[applicationId][msg.sender] == 
            (application.status == SkillStorage.SkillStatus.Verified);

        if (votedCorrectly) {
            // Simplistic reward distribution - divide equally among all voters
            uint256 totalVotes = _skillVotesFor[applicationId] + _skillVotesAgainst[applicationId];
            if (totalVotes > 0) {
                amount = _fees.skillVerificationFee / totalVotes;
                if (amount > 0) {
                    payable(msg.sender).transfer(amount);
                }
            }
        }

        return amount;
    }

    /**
     * @dev Claim skill verification fee refund
     */
    function claimSkillVerificationFeeRefund(
        string calldata skillName
    ) external nonReentrant returns (uint256 amount) {
        uint256 applicationId = _skillApplicationIds[msg.sender][skillName];
        require(applicationId != 0, "No application found");

        SkillStorage.SkillApplication storage application = _skillApplications[applicationId];

        if (application.status == SkillStorage.SkillStatus.Verified) {
            // Applicant gets fee back if approved
            amount = _fees.skillVerificationFee;
            payable(msg.sender).transfer(amount);
        }

        return amount;
    }

    // QUESTION ENGINE FUNCTIONS

    /**
     * @dev Ask a question to Athena
     */
    function askAthena(
        string calldata questionHash,
        string calldata oracleName,
        uint256 /* fee */ // Ignored for backward compatibility
    ) external payable nonReentrant returns (uint256 questionId) {
        require(msg.value >= _fees.questionFee, "Insufficient fee");
        require(_oracleEngine.isActive(oracleName), "Oracle not active");

        // Create a new question
        questionId = _nextQuestionId++;

        _questions[questionId] = QuestionStorage.Question({
            id: questionId,
            asker: msg.sender,
            questionHash: questionHash,
            oracleName: oracleName,
            status: QuestionStorage.QuestionStatus.Asked,
            createdAt: block.timestamp,
            answeredAt: 0
        });

        emit QuestionAsked(questionId, msg.sender, questionHash, oracleName);

        return questionId;
    }

    /**
     * @dev Vote on a question
     */
    function voteOnQuestion(
    uint256 questionId,
    bool inFavor,
    string calldata reasonHash
) external returns (bool) {
    QuestionStorage.Question storage question = _questions[questionId];
    require(question.id != 0, "Question does not exist");
    require(question.status == QuestionStorage.QuestionStatus.Asked, "Not in asked state");
    require(!_hasVotedOnQuestion[questionId][msg.sender], "Already voted");

    // Verify the voter is part of the oracle
    string memory oracleName = question.oracleName;
    require(_oracleEngine.isOracleMember(oracleName, msg.sender), "Not an oracle member");

    // Record the vote
    _hasVotedOnQuestion[questionId][msg.sender] = true;
    _questionVoteChoice[questionId][msg.sender] = inFavor;

    if (inFavor) {
        _questionVotesFor[questionId]++;
    } else {
        _questionVotesAgainst[questionId]++;
    }

    _questionVoteReasons[questionId].push(reasonHash);

    emit QuestionVoteCast(questionId, msg.sender, inFavor, reasonHash);

    // Check if there are enough votes to make a decision
    uint256 totalVotes = _questionVotesFor[questionId] + _questionVotesAgainst[questionId];

    // If more than half of the oracle members have voted and the majority is positive, mark as answered
    if (_oracleEngine.isActive(oracleName)) {
        (,,,,,uint256 memberCount) = _oracleEngine.getOracleDetails(oracleName);

        if (totalVotes >= (memberCount / 2) + 1 && _questionVotesFor[questionId] > _questionVotesAgainst[questionId]) {
            question.status = QuestionStorage.QuestionStatus.Answered;
            question.answeredAt = block.timestamp;

            emit QuestionAnswered(questionId, reasonHash);
        }
    }

    // Record governance action in both DAO contracts
    _recordGovernanceAction(msg.sender);

    return true;
}

    /**
     * @dev Get question details
     */
    function getQuestionDetails(uint256 questionId) external view returns (
        QuestionStorage.Question memory question,
        uint256 votesFor,
        uint256 votesAgainst
    ) {
        return (
            _questions[questionId],
            _questionVotesFor[questionId],
            _questionVotesAgainst[questionId]
        );
    }

    /**
     * @dev Get question votes
     */
    function getQuestionVotes(uint256 questionId) external view returns (uint256 votesFor, uint256 votesAgainst) {
        return (_questionVotesFor[questionId], _questionVotesAgainst[questionId]);
    }

    /**
     * @dev Claim question fee reward
     */
    function claimQuestionFeeReward(uint256 questionId) external nonReentrant returns (uint256 amount) {
        QuestionStorage.Question storage question = _questions[questionId];
        require(question.id != 0, "Question does not exist");
        require(question.status != QuestionStorage.QuestionStatus.Asked, "Question not answered/expired");
        require(_hasVotedOnQuestion[questionId][msg.sender], "Did not vote");

        bool votedCorrectly = _questionVoteChoice[questionId][msg.sender] == 
            (question.status == QuestionStorage.QuestionStatus.Answered);

        if (votedCorrectly) {
            // Simplistic reward distribution - divide equally among all voters
            uint256 totalVotes = _questionVotesFor[questionId] + _questionVotesAgainst[questionId];
            if (totalVotes > 0) {
                amount = _fees.questionFee / totalVotes;
                if (amount > 0) {
                    payable(msg.sender).transfer(amount);
                }
            }
        }

        return amount;
    }

    /**
     * @dev Claim question fee refund
     */
    function claimQuestionFeeRefund(uint256 questionId) external nonReentrant returns (uint256 amount) {
        QuestionStorage.Question storage question = _questions[questionId];
        require(question.id != 0, "Question does not exist");
        require(question.asker == msg.sender, "Not the asker");

        if (question.status == QuestionStorage.QuestionStatus.Answered) {
            // Asker gets a portion of the fee back if the question is answered
            amount = _fees.questionFee / 2;
            payable(msg.sender).transfer(amount);
        } else if (question.status == QuestionStorage.QuestionStatus.Expired) {
            // Full refund if expired
            amount = _fees.questionFee;
            payable(msg.sender).transfer(amount);
        }

        return amount;
    }

    // ADMIN FUNCTIONS

    /**
     * @dev Set the skill verification fee
     */
    function updateSkillVerificationFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = _fees.skillVerificationFee;
        _fees.skillVerificationFee = newFee;

        emit FeeUpdated("SkillVerificationFee", newFee);
        emit ParameterUpdated("SkillVerificationFee", oldFee, newFee);
    }

    /**
     * @dev Set the question fee
     */
    function updateQuestionFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = _fees.questionFee;
        _fees.questionFee = newFee;

        emit FeeUpdated("QuestionFee", newFee);
        emit ParameterUpdated("QuestionFee", oldFee, newFee);
    }

    /**
     * @dev Set the skill voting period
     */
    function updateSkillVotingPeriod(uint256 newPeriod) external onlyOwner {
        uint256 oldPeriod = _votingPeriods.skillVotingPeriod;
        _votingPeriods.skillVotingPeriod = newPeriod;

        emit ParameterUpdated("SkillVotingPeriod", oldPeriod, newPeriod);
    }

    /**
     * @dev Set the question voting period
     */
    function updateQuestionVotingPeriod(uint256 newPeriod) external onlyOwner {
        uint256 oldPeriod = _votingPeriods.questionVotingPeriod;
        _votingPeriods.questionVotingPeriod = newPeriod;

        emit ParameterUpdated("QuestionVotingPeriod", oldPeriod, newPeriod);
    }

    /**
     * @dev Set the dispute engine contract reference
     */
    function setDisputeEngineContract(address newContract) external onlyOwner {
        _disputeEngine = IDisputeEngine(newContract);
        _oracleEngine = IOracleEngine(newContract); // Same contract for dispute and oracle functionality

        emit ContractReferenceUpdated("DisputeEngine", newContract);
    }

    /**
     * @dev Set the DAO contract reference
     */
    function setDAOContract(address newContract) external onlyOwner {
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
     * @param newContract Address of the GovernanceActionTracker contract
     */
    function setGovernanceActionTrackerContract(address newContract) external onlyOwner {
        require(newContract != address(0), "Invalid Governance Action Tracker address");
        _governanceActionTracker = IGovernanceActionTracker(newContract);

        emit ContractReferenceUpdated("GovernanceActionTracker", newContract);
    }

    /**
     * @dev Helper function to record governance actions in both DAO contracts
     * @param user The address of the user performing the governance action
     */
    function _recordGovernanceAction(address user) internal {
        // First try the Governance Action Tracker as the centralized source
        if (address(_governanceActionTracker) != address(0)) {
            try _governanceActionTracker.recordGovernanceAction(user) {
                // Action recorded successfully in centralized tracker
                return; // Early return as this is now the source of truth
            } catch {
                // Continue to legacy methods if tracking fails
            }
        }

        // If tracker not available, try the centralized Native DAO Governance
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
     * @dev Receive function to accept ether
     */
    receive() external payable {
        // Allow contract to receive ether
    }



    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     * Required by UUPSUpgradeable.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

