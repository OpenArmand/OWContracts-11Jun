// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IGovernanceActionTracker.sol";

/**
 * @title ICompleteSkillOracleManager
 * @dev Complete interface for the Skill Oracle Manager contract
 */
interface ICompleteSkillOracleManager {
    /**
     * @dev Record a verification action performed by a verifier
     * @param verifier Address of the verifier
     * @param actionWeight Weight of the verification action
     */
    function recordVerifierAction(address verifier, uint256 actionWeight) external;
    
    /**
     * @dev Check if a user is an active verifier
     * @param user Address of the user
     * @return Whether the user is an active verifier
     */
    function isActiveVerifier(address user) external view returns (bool);
    
    /**
     * @dev Get the verifier level of a user
     * @param user Address of the user
     * @return Verifier level (0-3, or max uint256 if not a verifier)
     */
    function getVerifierLevel(address user) external view returns (uint256);
    
    /**
     * @dev Update minimum members required for an oracle
     * @param newMinimumMembers New minimum members value
     * @return success True if the update was successful
     */
    function updateMinimumMembers(uint8 newMinimumMembers) external returns (bool success);
    
    /**
     * @dev Set the governance contract address
     * @param governanceAddress Address of the governance contract
     */
    function setGovernanceContract(address governanceAddress) external;
    
    /**
     * @dev Register a new skill
     * @param skillName Name of the skill
     * @param ipfsHash IPFS hash of the skill description
     * @param requiredStake Minimum stake required for oracle members
     * @return success True if the skill was successfully registered
     */
    function registerSkill(
        string calldata skillName,
        string calldata ipfsHash,
        uint256 requiredStake
    ) external returns (bool success);
    
    /**
     * @dev Add a member to an oracle
     * @param oracleName Name of the oracle (same as skill name)
     * @param member Address of the member
     * @param stake Amount of tokens staked
     * @return success True if the member was successfully added
     */
    function addOracleMember(
        string calldata oracleName,
        address member,
        uint256 stake
    ) external returns (bool success);
    
    /**
     * @dev Remove a member from an oracle
     * @param oracleName Name of the oracle
     * @param member Address of the member
     * @return success True if the member was successfully removed
     */
    function removeOracleMember(
        string calldata oracleName,
        address member
    ) external returns (bool success);
    
    /**
     * @dev Update a member's stake in an oracle
     * @param oracleName Name of the oracle
     * @param member Address of the member
     * @param newStake New stake amount
     * @return success True if the stake was successfully updated
     */
    function updateOracleMemberStake(
        string calldata oracleName,
        address member,
        uint256 newStake
    ) external returns (bool success);
    
    /**
     * @dev Updates the minimum stake requirement
     * @param newMinimumStake The new minimum stake amount
     * @return success True if the update was successful
     */
    function updateMinimumStake(
        uint256 newMinimumStake
    ) external returns (bool success);
    
    /**
     * @dev Verifies a user's skill
     * @param user Address of the user
     * @param skillName Name of the skill
     */
    function verifyUserSkill(address user, string calldata skillName) external;
    
    /**
     * @dev Add skills in bulk
     * @param skillNames Array of skill names
     * @param ipfsHashes Array of IPFS hashes
     * @return success True if the skills were successfully added
     */
    function addSkills(
        string[] calldata skillNames,
        string[] calldata ipfsHashes
    ) external returns (bool success);
    
    /**
     * @dev Remove skills in bulk
     * @param skillNames Array of skill names
     * @return success True if the skills were successfully removed
     */
    function removeSkills(
        string[] calldata skillNames
    ) external returns (bool success);
    
    /**
     * @dev Add an oracle for a skill
     * @param skillName Name of the skill
     * @return success True if the oracle was successfully added
     */
    function addOracle(string calldata skillName) external returns (bool success);
    
    /**
     * @dev Add a member to a skill oracle
     * @param oracleName Name of the oracle
     * @param members Array of member addresses
     * @param stakes Array of stake amounts
     * @return success True if the members were successfully added
     */
    function addMemberToSkillOracle(
        string calldata oracleName,
        address[] calldata members,
        uint256[] calldata stakes
    ) external returns (bool success);
    
    /**
     * @dev Remove members from an oracle
     * @param oracleName Name of the oracle
     * @param members Array of member addresses
     * @return success True if the members were successfully removed
     */
    function removeMembers(
        string calldata oracleName,
        address[] calldata members
    ) external returns (bool success);
    
    /**
     * @dev Set an oracle as active
     * @param oracleName Name of the oracle
     * @param isActive Whether the oracle should be active
     * @return success True if the oracle was successfully updated
     */
    function setOracleActive(
        string calldata oracleName,
        bool isActive
    ) external returns (bool success);
    
    /**
     * @dev Remove stake from a member as a penalty
     * @param oracleName Name of the oracle
     * @param member Address of the member
     * @param amount Amount to remove
     * @return success True if the stake was successfully removed
     */
    function removeStake(
        string calldata oracleName,
        address member,
        uint256 amount
    ) external returns (bool success);
    
    /**
     * @dev Checks if a user is an oracle member
     * @param oracleName Name of the oracle
     * @param member Address of the member
     * @return exists True if the member exists
     */
    function isOracleMember(string memory oracleName, address member) external view returns (bool exists);
    
    /**
     * @dev Gets the stake of an oracle member
     * @param oracleName Name of the oracle
     * @param member Address of the member
     * @return stake The stake amount
     */
    function getOracleMemberStake(string memory oracleName, address member) external view returns (uint256 stake);
    
    /**
     * @dev Checks if a skill is registered
     * @param skillName Name of the skill
     * @return registered True if the skill is registered
     */
    function isSkillRegistered(string memory skillName) external view returns (bool registered);
    
    /**
     * @dev Gets the oracle name for a skill
     * @param skillName Name of the skill
     * @return oracleName The oracle name
     */
    function getSkillOracleName(string memory skillName) external view returns (string memory oracleName);
    
    /**
     * @dev Checks if a user has a verified skill
     * @param user Address of the user
     * @param skillName Name of the skill
     * @return hasSkill True if the user has the skill
     */
    function hasUserSkill(address user, string memory skillName) external view returns (bool hasSkill);
    
    /**
     * @dev Gets the total staked amount in an oracle
     * @param oracleName Name of the oracle
     * @return amount The total staked amount
     */
    function getOracleTotalStaked(string memory oracleName) external view returns (uint256 amount);
    
    /**
     * @dev Gets the member count of an oracle
     * @param oracleName Name of the oracle
     * @return count The member count
     */
    function getOracleMemberCount(string memory oracleName) external view returns (uint256 count);
    
    /**
     * @dev Checks if an oracle is active
     * @param oracleName Name of the oracle
     * @return active True if the oracle is active
     */
    function isOracleActive(string memory oracleName) external view returns (bool active);
    
    /**
     * @dev Gets the IPFS hash of a skill
     * @param skillName Name of the skill
     * @return ipfsHash The IPFS hash
     */
    function getSkillIpfsHash(string memory skillName) external view returns (string memory ipfsHash);
    
    /**
     * @dev Gets the verification date of a user's skill
     * @param user Address of the user
     * @param skillName Name of the skill
     * @return verificationDate The verification date
     */
    function getUserSkillVerificationDate(address user, string memory skillName) external view returns (uint256 verificationDate);
}

/**
 * @title ICompleteNativeDAOGovernance
 * @dev Complete interface for the Native DAO Governance contract
 */
interface ICompleteNativeDAOGovernance {
    /**
     * @dev Check if a user has voting rights
     * @param user Address of the user
     * @return Whether the user has voting rights
     */
    function hasVotingRights(address user) external view returns (bool);
    
    /**
     * @dev Get the voting power of a user
     * @param user Address of the user
     * @return Voting power amount
     */
    function getVotingPower(address user) external view returns (uint256);
    
    /**
     * @dev Record governance action for a user
     * @param user Address of the user
     * @param actionWeight Weight of the governance action
     */
    function recordGovernanceAction(address user, uint256 actionWeight) external;
    
    /**
     * @dev Get the required action threshold for a governance level
     * @param level Governance level
     * @return Required action threshold
     */
    function getRequiredActionThreshold(uint256 level) external view returns (uint256);
    
    /**
     * @dev Send skill verification information to governance contract
     * @param user Address of the user
     * @param skillName Name of the skill
     * @param verificationDate Date of verification
     */
    function sendSkillVerification(address user, string calldata skillName, uint256 verificationDate) external;
}

/**
 * @title SkillOracleManager
 * @dev Implementation of the Skill Oracle Manager Contract on the OpenWork Chain
 * This contract manages skills, oracles, and user verification
 */
contract SkillOracleManager is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    ICompleteSkillOracleManager
{
    ICompleteNativeDAOGovernance public daoGovernance;
    
    // Governance Action Tracker for tracking governance actions
    IGovernanceActionTracker public governanceActionTracker;
    
    uint8 public minimumOracleMembers; // Default 20 members to activate oracle
    uint256 public minimumStake;    // Default 100,000 tokens
    
    struct Skill {
        string name;
        string ipfsHash;
        bool exists;
    }
    
    struct Oracle {
        string skillName;
        bool isActive;
        uint256 totalStaked;
        uint256 memberCount;
    }
    
    struct OracleMember {
        address memberAddress;
        uint256 stakedAmount;
        bool isActive;
    }
    
    struct UserSkill {
        string skillName;
        uint256 verificationDate;
        bool isVerified;
    }
    
    // Mappings
    mapping(string => Skill) private skills;
    mapping(string => Oracle) private oracles;
    mapping(string => mapping(address => OracleMember)) private oracleMembers;
    mapping(address => mapping(string => UserSkill)) private userSkills;
    mapping(address => mapping(string => uint256)) private memberVotingPower;
    
    // Store oracle member addresses for each oracle
    mapping(string => address[]) private oracleMemberAddresses;
    
    // Events
    event SkillRegistered(string indexed skillName, string ipfsHash);
    event SkillRemoved(string indexed skillName);
    event OracleMemberAdded(string indexed oracleName, address indexed member, uint256 stake);
    event OracleMemberRemoved(string indexed oracleName, address indexed member);
    event OracleMemberStakeUpdated(string indexed oracleName, address indexed member, uint256 newStake);
    event UserSkillVerified(address indexed user, string indexed skillName);
    event MinimumStakeUpdated(uint256 newMinimumStake);
    event MinimumMembersUpdated(uint8 newMinimumMembers);
    event OracleActive(string indexed oracleName, bool isActive);
    event GovernanceContractSet(address governanceAddress);
    event GovernanceActionTrackerSet(address trackerAddress);
    
    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initialize the contract with initial owner
     * @param initialOwner Address of the initial owner
     */
    function initialize(
        address initialOwner
    ) external initializer {
        // Don't call the standard init functions as they set the msg.sender as owner
        // Instead, manually initialize and set the provided owner
        
        // Initialize base contracts without setting owner
        __ReentrancyGuard_init_unchained();
        __UUPSUpgradeable_init_unchained();
        
        // Custom initialization for Ownable
        // Skip __Ownable_init() since it would set msg.sender as owner
        _transferOwnership(initialOwner);
        
        // Default values that can be changed later
        minimumStake = 100000; // Default 100,000 tokens
        minimumOracleMembers = 20; // Default 20 members
    }
    
    /**
     * @dev Set the minimum stake required for oracle membership
     * @param _minimumStake Minimum stake value
     * @return success True if successful
     */
    function updateMinimumStake(
        uint256 _minimumStake
    ) external onlyOwner returns (bool success) {
        require(_minimumStake > 0, "Minimum stake must be greater than 0");
        
        minimumStake = _minimumStake;
        
        emit MinimumStakeUpdated(_minimumStake);
        return true;
    }
    
    /**
     * @dev Set the minimum members required for oracle activation
     * @param _minimumOracleMembers Minimum members value
     * @return success True if successful
     */
    function updateMinimumMembers(
        uint8 _minimumOracleMembers
    ) external onlyOwner returns (bool success) {
        require(_minimumOracleMembers > 0, "Minimum members must be greater than 0");
        
        minimumOracleMembers = _minimumOracleMembers;
        
        emit MinimumMembersUpdated(_minimumOracleMembers);
        return true;
    }
    
    /**
     * @dev Set the governance contract address
     * @param governanceAddress Address of the governance contract
     */
    function setGovernanceContract(address governanceAddress) external onlyOwner {
        require(governanceAddress != address(0), "Invalid governance address");
        daoGovernance = ICompleteNativeDAOGovernance(governanceAddress);
        emit GovernanceContractSet(governanceAddress);
    }
    
    /**
     * @dev Set the Governance Action Tracker contract
     * @param trackerAddress Address of the Governance Action Tracker contract
     */
    function setGovernanceActionTracker(address trackerAddress) external onlyOwner {
        require(trackerAddress != address(0), "Invalid tracker address");
        governanceActionTracker = IGovernanceActionTracker(trackerAddress);
        emit GovernanceActionTrackerSet(trackerAddress);
    }
    
    /**
     * @dev Modifier to ensure caller is the governance contract
     */
    modifier onlyGovernance() {
        require(msg.sender == address(daoGovernance) || msg.sender == owner(), "Caller is not governance");
        _;
    }
    
    /**
     * @dev Register a new skill
     * @param skillName Name of the skill
     * @param ipfsHash IPFS hash of the skill description
     * @param requiredStake Minimum stake required for oracle members
     * @return success True if the skill was successfully registered
     */
    function registerSkill(
        string calldata skillName,
        string calldata ipfsHash,
        uint256 requiredStake
    ) external onlyGovernance returns (bool success) {
        require(bytes(skillName).length > 0, "Skill name cannot be empty");
        require(bytes(ipfsHash).length > 0, "IPFS hash cannot be empty");
        require(!skills[skillName].exists, "Skill already registered");
        require(requiredStake >= minimumStake, "Stake too low");
        
        skills[skillName] = Skill({
            name: skillName,
            ipfsHash: ipfsHash,
            exists: true
        });
        
        oracles[skillName] = Oracle({
            skillName: skillName,
            isActive: false,
            totalStaked: 0,
            memberCount: 0
        });
        
        emit SkillRegistered(skillName, ipfsHash);
        return true;
    }
    
    /**
     * @dev Add a member to an oracle
     * @param oracleName Name of the oracle (same as skill name)
     * @param member Address of the member
     * @param stake Amount of tokens staked
     * @return success True if the member was successfully added
     */
    function addOracleMember(
        string calldata oracleName,
        address member,
        uint256 stake
    ) external onlyGovernance returns (bool success) {
        require(skills[oracleName].exists, "Skill/Oracle does not exist");
        require(!oracleMembers[oracleName][member].isActive, "Already a member");
        require(stake >= minimumStake, "Stake too low");
        
        oracleMembers[oracleName][member] = OracleMember({
            memberAddress: member,
            stakedAmount: stake,
            isActive: true
        });
        
        oracleMemberAddresses[oracleName].push(member);
        
        oracles[oracleName].totalStaked += stake;
        oracles[oracleName].memberCount++;
        
        // Activate oracle if minimum member threshold reached
        if (oracles[oracleName].memberCount >= minimumOracleMembers && !oracles[oracleName].isActive) {
            oracles[oracleName].isActive = true;
            emit OracleActive(oracleName, true);
        }
        
        // Calculate voting power based on stake
        memberVotingPower[member][oracleName] = stake;
        
        emit OracleMemberAdded(oracleName, member, stake);
        return true;
    }
    
    /**
     * @dev Remove a member from an oracle
     * @param oracleName Name of the oracle
     * @param member Address of the member
     * @return success True if the member was successfully removed
     */
    function removeOracleMember(
        string calldata oracleName,
        address member
    ) external onlyGovernance returns (bool success) {
        require(skills[oracleName].exists, "Skill/Oracle does not exist");
        require(oracleMembers[oracleName][member].isActive, "Not a member");
        
        uint256 stake = oracleMembers[oracleName][member].stakedAmount;
        
        oracleMembers[oracleName][member].isActive = false;
        oracleMembers[oracleName][member].stakedAmount = 0;
        
        oracles[oracleName].totalStaked -= stake;
        oracles[oracleName].memberCount--;
        
        // Deactivate oracle if member count falls below threshold
        if (oracles[oracleName].memberCount < minimumOracleMembers && oracles[oracleName].isActive) {
            oracles[oracleName].isActive = false;
            emit OracleActive(oracleName, false);
        }
        
        // Reset voting power
        memberVotingPower[member][oracleName] = 0;
        
        emit OracleMemberRemoved(oracleName, member);
        return true;
    }
    
    /**
     * @dev Update a member's stake in an oracle
     * @param oracleName Name of the oracle
     * @param member Address of the member
     * @param newStake New stake amount
     * @return success True if the stake was successfully updated
     */
    function updateOracleMemberStake(
        string calldata oracleName,
        address member,
        uint256 newStake
    ) external onlyGovernance returns (bool success) {
        require(skills[oracleName].exists, "Skill/Oracle does not exist");
        require(oracleMembers[oracleName][member].isActive, "Not a member");
        require(newStake >= minimumStake, "Stake too low");
        
        uint256 oldStake = oracleMembers[oracleName][member].stakedAmount;
        
        oracleMembers[oracleName][member].stakedAmount = newStake;
        
        oracles[oracleName].totalStaked = oracles[oracleName].totalStaked - oldStake + newStake;
        
        // Update voting power
        memberVotingPower[member][oracleName] = newStake;
        
        emit OracleMemberStakeUpdated(oracleName, member, newStake);
        return true;
    }
    
    /**
     * @dev Verifies a user's skill
     * @param user Address of the user
     * @param skillName Name of the skill
     */
    function verifyUserSkill(address user, string calldata skillName) external {
        require(skills[skillName].exists, "Skill does not exist");
        require(oracles[skillName].isActive, "Oracle not active");
        require(isOracleMember(skillName, msg.sender), "Not an oracle member");
        
        uint256 verificationDate = block.timestamp;
        
        userSkills[user][skillName] = UserSkill({
            skillName: skillName,
            verificationDate: verificationDate,
            isVerified: true
        });
        
        // Notify governance contract about the verification
        if (address(daoGovernance) != address(0)) {
            daoGovernance.sendSkillVerification(user, skillName, verificationDate);
        }
        
        // Record governance action for the verifier
        if (address(governanceActionTracker) != address(0)) {
            governanceActionTracker.recordGovernanceAction(msg.sender);
        }
        
        emit UserSkillVerified(user, skillName);
    }
    
    /**
     * @dev Add skills in bulk
     * @param skillNames Array of skill names
     * @param ipfsHashes Array of IPFS hashes
     * @return success True if the skills were successfully added
     */
    function addSkills(
        string[] calldata skillNames,
        string[] calldata ipfsHashes
    ) external onlyGovernance returns (bool success) {
        require(skillNames.length == ipfsHashes.length, "Arrays length mismatch");
        
        for (uint256 i = 0; i < skillNames.length; i++) {
            require(bytes(skillNames[i]).length > 0, "Skill name cannot be empty");
            require(bytes(ipfsHashes[i]).length > 0, "IPFS hash cannot be empty");
            require(!skills[skillNames[i]].exists, "Skill already registered");
            
            skills[skillNames[i]] = Skill({
                name: skillNames[i],
                ipfsHash: ipfsHashes[i],
                exists: true
            });
            
            oracles[skillNames[i]] = Oracle({
                skillName: skillNames[i],
                isActive: false,
                totalStaked: 0,
                memberCount: 0
            });
            
            emit SkillRegistered(skillNames[i], ipfsHashes[i]);
        }
        
        return true;
    }
    
    /**
     * @dev Remove skills in bulk
     * @param skillNames Array of skill names
     * @return success True if the skills were successfully removed
     */
    function removeSkills(
        string[] calldata skillNames
    ) external onlyGovernance returns (bool success) {
        for (uint256 i = 0; i < skillNames.length; i++) {
            require(skills[skillNames[i]].exists, "Skill does not exist");
            
            // If the oracle is active, we should handle members first
            if (oracles[skillNames[i]].isActive) {
                require(oracles[skillNames[i]].memberCount == 0, "Oracle has members");
            }
            
            delete skills[skillNames[i]];
            delete oracles[skillNames[i]];
            
            emit SkillRemoved(skillNames[i]);
        }
        
        return true;
    }
    
    /**
     * @dev Add an oracle for a skill
     * @param skillName Name of the skill
     * @return success True if the oracle was successfully added
     */
    function addOracle(string calldata skillName) external onlyGovernance returns (bool success) {
        require(skills[skillName].exists, "Skill does not exist");
        
        // Oracle already exists with the same name as the skill, but might be inactive
        if (!oracles[skillName].isActive) {
            oracles[skillName].isActive = false;
            oracles[skillName].totalStaked = 0;
            oracles[skillName].memberCount = 0;
        }
        
        return true;
    }
    
    /**
     * @dev Add a member to a skill oracle
     * @param oracleName Name of the oracle
     * @param members Array of member addresses
     * @param stakes Array of stake amounts
     * @return success True if the members were successfully added
     */
    function addMemberToSkillOracle(
        string calldata oracleName,
        address[] calldata members,
        uint256[] calldata stakes
    ) external onlyGovernance returns (bool success) {
        require(members.length == stakes.length, "Arrays length mismatch");
        require(skills[oracleName].exists, "Skill/Oracle does not exist");
        
        for (uint256 i = 0; i < members.length; i++) {
            require(!oracleMembers[oracleName][members[i]].isActive, "Already a member");
            require(stakes[i] >= minimumStake, "Stake too low");
            
            oracleMembers[oracleName][members[i]] = OracleMember({
                memberAddress: members[i],
                stakedAmount: stakes[i],
                isActive: true
            });
            
            oracleMemberAddresses[oracleName].push(members[i]);
            
            oracles[oracleName].totalStaked += stakes[i];
            oracles[oracleName].memberCount++;
            
            // Calculate voting power based on stake
            memberVotingPower[members[i]][oracleName] = stakes[i];
            
            emit OracleMemberAdded(oracleName, members[i], stakes[i]);
        }
        
        // Activate oracle if minimum member threshold reached
        if (oracles[oracleName].memberCount >= minimumOracleMembers && !oracles[oracleName].isActive) {
            oracles[oracleName].isActive = true;
            emit OracleActive(oracleName, true);
        }
        
        return true;
    }
    
    /**
     * @dev Remove members from an oracle
     * @param oracleName Name of the oracle
     * @param members Array of member addresses
     * @return success True if the members were successfully removed
     */
    function removeMembers(
        string calldata oracleName,
        address[] calldata members
    ) external onlyGovernance returns (bool success) {
        require(skills[oracleName].exists, "Skill/Oracle does not exist");
        
        for (uint256 i = 0; i < members.length; i++) {
            require(oracleMembers[oracleName][members[i]].isActive, "Not a member");
            
            uint256 stake = oracleMembers[oracleName][members[i]].stakedAmount;
            
            oracleMembers[oracleName][members[i]].isActive = false;
            oracleMembers[oracleName][members[i]].stakedAmount = 0;
            
            oracles[oracleName].totalStaked -= stake;
            oracles[oracleName].memberCount--;
            
            // Reset voting power
            memberVotingPower[members[i]][oracleName] = 0;
            
            emit OracleMemberRemoved(oracleName, members[i]);
        }
        
        // Deactivate oracle if member count falls below threshold
        if (oracles[oracleName].memberCount < minimumOracleMembers && oracles[oracleName].isActive) {
            oracles[oracleName].isActive = false;
            emit OracleActive(oracleName, false);
        }
        
        return true;
    }
    
    /**
     * @dev Set an oracle as active
     * @param oracleName Name of the oracle
     * @param isActive Whether the oracle should be active
     * @return success True if the oracle was successfully updated
     */
    function setOracleActive(
        string calldata oracleName,
        bool isActive
    ) external onlyGovernance returns (bool success) {
        require(skills[oracleName].exists, "Skill/Oracle does not exist");
        
        if (isActive) {
            require(oracles[oracleName].memberCount >= minimumOracleMembers, "Not enough members");
        }
        
        oracles[oracleName].isActive = isActive;
        emit OracleActive(oracleName, isActive);
        
        return true;
    }
    
    /**
     * @dev Remove stake from a member as a penalty
     * @param oracleName Name of the oracle
     * @param member Address of the member
     * @param amount Amount to remove
     * @return success True if the stake was successfully removed
     */
    function removeStake(
        string calldata oracleName,
        address member,
        uint256 amount
    ) external onlyGovernance returns (bool success) {
        require(skills[oracleName].exists, "Skill/Oracle does not exist");
        require(oracleMembers[oracleName][member].isActive, "Not a member");
        require(amount <= oracleMembers[oracleName][member].stakedAmount, "Amount too high");
        
        oracleMembers[oracleName][member].stakedAmount -= amount;
        oracles[oracleName].totalStaked -= amount;
        
        // Update voting power
        memberVotingPower[member][oracleName] = oracleMembers[oracleName][member].stakedAmount;
        
        // If stake becomes less than minimum, remove member
        if (oracleMembers[oracleName][member].stakedAmount < minimumStake) {
            oracleMembers[oracleName][member].isActive = false;
            oracles[oracleName].memberCount--;
            
            // Deactivate oracle if member count falls below threshold
            if (oracles[oracleName].memberCount < minimumOracleMembers && oracles[oracleName].isActive) {
                oracles[oracleName].isActive = false;
                emit OracleActive(oracleName, false);
            }
            
            emit OracleMemberRemoved(oracleName, member);
        } else {
            emit OracleMemberStakeUpdated(oracleName, member, oracleMembers[oracleName][member].stakedAmount);
        }
        
        return true;
    }
    
    /**
     * @dev Checks if a user is an oracle member
     * @param oracleName Name of the oracle
     * @param member Address of the member
     * @return exists True if the member exists
     */
    function isOracleMember(string memory oracleName, address member) public view returns (bool exists) {
        return oracleMembers[oracleName][member].isActive;
    }
    
    /**
     * @dev Gets the stake of an oracle member
     * @param oracleName Name of the oracle
     * @param member Address of the member
     * @return stake The stake amount
     */
    function getOracleMemberStake(string memory oracleName, address member) public view returns (uint256 stake) {
        return oracleMembers[oracleName][member].stakedAmount;
    }
    
    /**
     * @dev Checks if a skill is registered
     * @param skillName Name of the skill
     * @return registered True if the skill is registered
     */
    function isSkillRegistered(string memory skillName) external view returns (bool registered) {
        return skills[skillName].exists;
    }
    
    /**
     * @dev Gets the oracle name for a skill
     * @param skillName Name of the skill
     * @return oracleName The oracle name
     */
    function getSkillOracleName(string memory skillName) external view returns (string memory oracleName) {
        require(skills[skillName].exists, "Skill does not exist");
        return skillName;
    }
    
    /**
     * @dev Checks if a user has a verified skill
     * @param user Address of the user
     * @param skillName Name of the skill
     * @return hasSkill True if the user has the skill
     */
    function hasUserSkill(address user, string memory skillName) external view returns (bool hasSkill) {
        return userSkills[user][skillName].isVerified;
    }
    
    /**
     * @dev Gets the total staked amount in an oracle
     * @param oracleName Name of the oracle
     * @return amount The total staked amount
     */
    function getOracleTotalStaked(string memory oracleName) external view returns (uint256 amount) {
        return oracles[oracleName].totalStaked;
    }
    
    /**
     * @dev Gets the member count of an oracle
     * @param oracleName Name of the oracle
     * @return count The member count
     */
    function getOracleMemberCount(string memory oracleName) external view returns (uint256 count) {
        return oracles[oracleName].memberCount;
    }
    
    /**
     * @dev Checks if an oracle is active
     * @param oracleName Name of the oracle
     * @return active True if the oracle is active
     */
    function isOracleActive(string memory oracleName) external view returns (bool active) {
        return oracles[oracleName].isActive;
    }
    
    /**
     * @dev Gets the IPFS hash of a skill
     * @param skillName Name of the skill
     * @return ipfsHash The IPFS hash
     */
    function getSkillIpfsHash(string memory skillName) external view returns (string memory ipfsHash) {
        require(skills[skillName].exists, "Skill does not exist");
        return skills[skillName].ipfsHash;
    }
    
    /**
     * @dev Gets the verification date of a user's skill
     * @param user Address of the user
     * @param skillName Name of the skill
     * @return verificationDate The verification date
     */
    function getUserSkillVerificationDate(address user, string memory skillName) external view returns (uint256 verificationDate) {
        return userSkills[user][skillName].verificationDate;
    }

    /**
     * @dev Record a verification action performed by a verifier
     * @param verifier Address of the verifier
     * @param actionWeight Weight of the verification action
     */
    function recordVerifierAction(address verifier, uint256 actionWeight) external {
        require(isOracleMember("active_verifier", verifier), "Not an active verifier");
        // Implementation would track verification actions
    }
    
    /**
     * @dev Check if a user is an active verifier
     * @param user Address of the user
     * @return Whether the user is an active verifier
     */
    function isActiveVerifier(address user) external view returns (bool) {
        return isOracleMember("active_verifier", user);
    }
    
    /**
     * @dev Get the verifier level of a user
     * @param user Address of the user
     * @return Verifier level (0-3, or max uint256 if not a verifier)
     */
    function getVerifierLevel(address user) external view returns (uint256) {
        if (!isOracleMember("active_verifier", user)) {
            return type(uint256).max;
        }
        
        // Direct access to the mapping instead of calling the external function
        uint256 stake = oracleMembers["active_verifier"][user].stakedAmount;
        
        if (stake >= 500000) return 3;
        if (stake >= 250000) return 2;
        if (stake >= 100000) return 1;
        return 0;
    }
    
    /**
     * @dev Gets all active members of an oracle
     * @param oracleName Name of the oracle
     * @return members Array of active member addresses
     */
    function getOracleMembers(string memory oracleName) external view returns (address[] memory members) {
        require(skills[oracleName].exists, "Oracle does not exist");
        
        address[] memory allMembers = oracleMemberAddresses[oracleName];
        uint256 activeCount = 0;
        
        // Count active members
        for (uint256 i = 0; i < allMembers.length; i++) {
            if (oracleMembers[oracleName][allMembers[i]].isActive) {
                activeCount++;
            }
        }
        
        // Create array of active members
        address[] memory activeMembers = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allMembers.length; i++) {
            if (oracleMembers[oracleName][allMembers[i]].isActive) {
                activeMembers[index] = allMembers[i];
                index++;
            }
        }
        
        return activeMembers;
    }
    
    /**
     * @dev Validates if an oracle meets dispute resolution requirements
     * @param oracleName Name of the oracle
     * @return isValid True if oracle can handle disputes
     */
    function validateOracleForDisputes(string memory oracleName) external view returns (bool isValid) {
        if (!skills[oracleName].exists) {
            return false;
        }
        
        Oracle storage oracle = oracles[oracleName];
        
        // Check if oracle is active and has minimum members
        return oracle.isActive && oracle.memberCount >= minimumOracleMembers;
    }
    
    /**
     * @dev Gets oracle member's voting weight for disputes
     * @param oracleName Name of the oracle
     * @param member Address of the member
     * @return weight Voting weight based on stake
     */
    function getOracleMemberVotingWeight(string memory oracleName, address member) external view returns (uint256 weight) {
        if (!skills[oracleName].exists) {
            return 0;
        }
        
        OracleMember storage oracleMember = oracleMembers[oracleName][member];
        if (!oracleMember.isActive) {
            return 0;
        }
        
        return oracleMember.stakedAmount;
    }

    /**
     * @dev Internal authorization function for contract upgrades
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    // Storage gap for future upgrades
    uint256[50] private __gap;
}