// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IOpenWorkDAO.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IOpenWorkBridge.sol";
import "./interfaces/IUnifiedRewardsTracking.sol";
import "./interfaces/IBridgeMessageReceiver.sol";
import "./interfaces/INativeDAOGovernance.sol";
import "./interfaces/IGovernanceActionTracker.sol";

/**
 * @title OpenWorkDAO
 * @dev Main DAO contract for the OpenWork ecosystem
 * Handles staking, DAO membership, team tokens, earned tokens, and cross-chain communication
 */
contract OpenWorkDAO is IOpenWorkDAO, 
    Initializable, 
    UUPSUpgradeable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable,
    IBridgeMessageReceiver
{
    // Constants
    uint256 public constant MIN_STAKE_AMOUNT = 100_000 * 10**18;
    uint256 public constant MIN_TEAM_TOKENS_FOR_VOTING = 100_000 * 10**18;
    uint256 public constant PROPOSAL_THRESHOLD = 1_000_000 * 10**18;
    uint256 public constant GOVERNANCE_ACTION_THRESHOLD = 10_000 * 10**18;
    // TESTING VALUE - CHANGE BACK TO 14 days FOR PRODUCTION
    uint256 public constant UNSTAKING_DELAY = 30 seconds;
    
    // Stake periods
    // TESTING VALUES - CHANGE BACK TO 1,2,3 FOR PRODUCTION
    // These represent multipliers but are also used for period identification
    uint8 public constant PERIOD_ONE_YEAR = 1;
    uint8 public constant PERIOD_TWO_YEARS = 2;
    uint8 public constant PERIOD_THREE_YEARS = 3;
    
    // Contract types for cross-chain registration
    uint8 public constant CONTRACT_TYPE_NATIVE_DAO = 1;
    uint8 public constant CONTRACT_TYPE_LOCAL_OPENWORK = 2;
    
    // Official OpenWork contract types
    uint8 public constant CONTRACT_TYPE_JOB_MARKETPLACE = 1;
    uint8 public constant CONTRACT_TYPE_STAKING = 2;
    uint8 public constant CONTRACT_TYPE_DISPUTE_RESOLUTION = 3;
    uint8 public constant CONTRACT_TYPE_TOKEN_BRIDGE = 4;
    uint8 public constant CONTRACT_TYPE_SKILL_ORACLE = 5;
    uint8 public constant CONTRACT_TYPE_PRICE_ORACLE = 6;
    uint8 public constant CONTRACT_TYPE_REWARDS = 7;
    
    // Message type constants
    uint8 public constant MESSAGE_TYPE_VERIFY_SKILL = 1;
    uint8 public constant MESSAGE_TYPE_MEMBER_VERIFICATION = 2;
    uint8 public constant MESSAGE_TYPE_DISPUTE_ESCALATION = 3;
    uint8 public constant MESSAGE_TYPE_CONTRACT_UPGRADE = 4;
    
    // Using OriginalContract struct defined in IOpenWorkDAO
    
    // State variables
    address public openWorkToken;
    address public governor;
    address public layerZeroBridge; // Changed from ccipBridge to layerZeroBridge
    address public earningsRewardsContract; // Points to IUnifiedRewardsTracking implementation
    address public treasury;
    IGovernanceActionTracker public governanceActionTracker; // Governance action tracker contract
    
    // Cross-chain contract addresses
    mapping(uint64 => address) public nativeDAOContracts;
    mapping(uint64 => address) public localOpenWorkContracts;
    
    // Official OpenWork contract addresses on all chains
    // chainId => contractType => OriginalContract
    mapping(uint64 => mapping(uint8 => OriginalContract)) public originalContracts;
    
    // DAO member details
    struct DAOMember {
        uint256 stakedAmount;
        uint8 stakePeriod;
        uint256 stakeDate;
        uint256 unlockDate;
        uint256 pendingUnstakeAmount;
        uint256 unstakeRequestDate;
        bool isActive;
    }
    
    // Using TeamTokens struct defined in IOpenWorkDAO
    
    // Mappings
    mapping(address => DAOMember) private _daoMembers;
    mapping(address => TeamTokens) private _teamTokens;
    mapping(address => uint256) private _governanceActions;
    
    // Events
    event DAOMemberJoined(address indexed member, uint256 amount, uint8 period);
    event AdditionalStaked(address indexed member, uint256 amount, uint8 period);
    event UnstakeRequested(address indexed member, uint256 amount);
    event UnstakeCancelled(address indexed member);
    event UnstakeCompleted(address indexed member, uint256 amount);
    event GovernanceActionRecorded(address indexed member, uint256 newTotal);
    event TeamTokensAssigned(address indexed member, uint256 oneYear, uint256 twoYear, uint256 threeYear);
    event TeamTokensClaimed(address indexed member, uint256 amount);
    event EarnedTokensClaimed(address indexed member, uint256 amount);
    event PenaltyApplied(address indexed member, uint256 amount);
    event CrossChainContractRegistered(uint64 chainId, uint8 contractType, address contractAddress);
    event CrossChainMessageSent(uint64 chainId, bytes32 messageId);
    event OriginalContractRegistered(uint64 chainId, uint8 contractType, address contractAddress, string contractName);
    event GovernanceActionTrackerSet(address trackerAddress);
    
    /**
     * @dev Modifier to check if the caller is authorized to perform governance actions
     * Only the owner, the Governor (through the timelock), or admin-designated controllers can call
     */
    modifier onlyAuthorized() {
        require(
            msg.sender == owner() || 
            msg.sender == address(this) ||
            msg.sender == governor,
            "Unauthorized"
        );
        _;
    }
    
    /**
     * @dev Initializer function
     * @param _token Address of the OpenWork token
     * @param _layerZeroBridge Address of the LayerZero bridge for cross-chain communication
     * @param _earningsRewardsContract Address of the Earnings and Rewards contract
     * @param _treasury Address of the treasury
     */
    function initialize(
        address _token,
        address _layerZeroBridge,
        address _earningsRewardsContract,
        address _treasury
    ) initializer public {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        
        openWorkToken = _token;
        layerZeroBridge = _layerZeroBridge;
        earningsRewardsContract = _earningsRewardsContract;
        treasury = _treasury;
    }
    
    /**
     * @dev Join the DAO by staking tokens
     * @param amount Amount of tokens to stake
     * @param period Staking period (1, 2, or 3 years)
     */
    function joinDAO(uint256 amount, uint8 period) external nonReentrant {
        require(!_daoMembers[msg.sender].isActive, "Already a DAO member");
        require(amount >= MIN_STAKE_AMOUNT, "Stake amount too low");
        require(period >= PERIOD_ONE_YEAR && period <= PERIOD_THREE_YEARS, "Invalid stake period");
        
        // Transfer tokens from user to this contract
        require(
            IERC20(openWorkToken).transferFrom(msg.sender, address(this), amount),
            "Token transfer failed"
        );
        
        // Calculate unlock date
        // TESTING VALUE - CHANGE BACK TO (period * 365 days) FOR PRODUCTION
        uint256 unlockTimestamp = block.timestamp + (period * 30 seconds);
        
        // Create DAO member
        _daoMembers[msg.sender] = DAOMember({
            stakedAmount: amount,
            stakePeriod: period,
            stakeDate: block.timestamp,
            unlockDate: unlockTimestamp,
            pendingUnstakeAmount: 0,
            unstakeRequestDate: 0,
            isActive: true
        });
        
        emit DAOMemberJoined(msg.sender, amount, period);
    }
    
    /**
     * @dev Stake additional tokens
     * @param amount Amount of additional tokens to stake
     * @param period New staking period (1, 2, or 3 years)
     */
    function stakeAdditional(uint256 amount, uint8 period) external nonReentrant {
        require(_daoMembers[msg.sender].isActive, "Not a DAO member");
        require(amount > 0, "Amount must be greater than 0");
        require(period >= PERIOD_ONE_YEAR && period <= PERIOD_THREE_YEARS, "Invalid stake period");
        
        // Transfer tokens from user to this contract
        require(
            IERC20(openWorkToken).transferFrom(msg.sender, address(this), amount),
            "Token transfer failed"
        );
        
        // Update stake details
        DAOMember storage member = _daoMembers[msg.sender];
        
        // Extend unlock date if new period is longer
        if (period > member.stakePeriod) {
            // Calculate new unlock date based on current date and new period
            // TESTING VALUE - CHANGE BACK TO (period * 365 days) FOR PRODUCTION
            uint256 newUnlockTimestamp = block.timestamp + (period * 30 seconds);
            member.unlockDate = newUnlockTimestamp;
            member.stakePeriod = period;
        }
        
        // Update staked amount
        member.stakedAmount += amount;
        
        emit AdditionalStaked(msg.sender, amount, period);
    }
    
    /**
     * @dev Request to unstake tokens
     * @param amount Amount of tokens to unstake
     */
    function requestUnstake(uint256 amount) external nonReentrant {
        DAOMember storage member = _daoMembers[msg.sender];
        
        require(member.isActive, "Not a DAO member");
        require(block.timestamp >= member.unlockDate, "Stake still locked");
        require(amount <= member.stakedAmount, "Insufficient staked tokens");
        require(member.pendingUnstakeAmount == 0, "Unstake already requested");
        
        // Update member details
        member.stakedAmount -= amount;
        member.pendingUnstakeAmount = amount;
        member.unstakeRequestDate = block.timestamp;
        
        // If remaining staked amount is below minimum, mark as inactive
        if (member.stakedAmount < MIN_STAKE_AMOUNT) {
            member.isActive = false;
        }
        
        emit UnstakeRequested(msg.sender, amount);
    }
    
    /**
     * @dev Cancel unstake request
     */
    function cancelUnstake() external nonReentrant {
        DAOMember storage member = _daoMembers[msg.sender];
        
        require(member.pendingUnstakeAmount > 0, "No pending unstake");
        
        // Restore staked amount
        member.stakedAmount += member.pendingUnstakeAmount;
        
        // Clear unstake request
        member.pendingUnstakeAmount = 0;
        member.unstakeRequestDate = 0;
        
        // If staked amount is now above minimum, reactivate membership
        if (member.stakedAmount >= MIN_STAKE_AMOUNT) {
            member.isActive = true;
        }
        
        emit UnstakeCancelled(msg.sender);
    }
    
    /**
     * @dev Complete unstake after delay period
     */
    function completeUnstake() external nonReentrant {
        DAOMember storage member = _daoMembers[msg.sender];
        
        require(member.pendingUnstakeAmount > 0, "No pending unstake");
        require(
            block.timestamp >= member.unstakeRequestDate + UNSTAKING_DELAY,
            "Unstake delay not passed"
        );
        
        uint256 amount = member.pendingUnstakeAmount;
        
        // Clear unstake request
        member.pendingUnstakeAmount = 0;
        member.unstakeRequestDate = 0;
        
        // Transfer tokens to the user
        require(
            IERC20(openWorkToken).transfer(msg.sender, amount),
            "Token transfer failed"
        );
        
        emit UnstakeCompleted(msg.sender, amount);
    }
    
    /**
     * @dev Record a governance action for a member
     * @param member Address of the DAO member
     */
    function recordGovernanceAction(address member) public override onlyAuthorized {
        // First try the new GovernanceActionTracker
        if (address(governanceActionTracker) != address(0)) {
            try governanceActionTracker.recordGovernanceAction(member) {
                // Successfully recorded in GovernanceActionTracker
                // No further actions needed as this is the centralized source
                return;
            } catch {
                // If call to GovernanceActionTracker fails, fall back to legacy methods
            }
        }

        // If GovernanceActionTracker is not set, try to record in NativeDAOGovernance
        uint64 currentChainId = uint64(block.chainid);
        address nativeDAOAddress = nativeDAOContracts[currentChainId];
        bool nativeRecorded = false;
        
        if (nativeDAOAddress != address(0)) {
            // NativeDAOGovernance is on this chain
            try INativeDAOGovernance(nativeDAOAddress).recordGovernanceAction(member) {
                nativeRecorded = true;
                // Successfully recorded in NativeDAOGovernance
            } catch {
                // If call to NativeDAOGovernance fails, fall back to local recording
                nativeRecorded = false;
            }
        } else {
            // Check if we have a bridge and NativeDAOGovernance on another chain
            if (layerZeroBridge != address(0)) {
                // Find which chain has NativeDAOGovernance
                for (uint64 chainId = 1; chainId <= 20; chainId++) {  // Reasonable limit to check chains
                    if (chainId != currentChainId && nativeDAOContracts[chainId] != address(0)) {
                        // Found NativeDAOGovernance on another chain
                        address targetNativeDAO = nativeDAOContracts[chainId];
                        
                        // Create cross-chain message:
                        // Message type 10 = recordGovernanceAction
                        bytes memory payload = abi.encode(10, member);
                        
                        try IOpenWorkBridge(layerZeroBridge).sendMessage(
                            uint16(chainId),
                            targetNativeDAO,
                            payload
                        ) returns (bytes32 messageId) {
                            nativeRecorded = true;
                            emit CrossChainMessageSent(chainId, messageId);
                            break;
                        } catch {
                            // If bridge call fails, continue to next chain or fall back to local recording
                        }
                    }
                }
            }
        }
        
        // If not recorded in either GovernanceActionTracker or NativeDAOGovernance, record locally
        if (!nativeRecorded) {
            _governanceActions[member]++;
            emit GovernanceActionRecorded(member, _governanceActions[member]);
        }
    }
    
    /**
     * @dev Calculate the voting power of a member
     * @param member The address of the member
     * @return The voting power of the member
     */
    function getVotingPower(address member) external view returns (uint256) {
        uint256 totalVotingPower = 0;
        
        // Add voting power from staked tokens if they are active members
        DAOMember memory daoMember = _daoMembers[member];
        if (daoMember.isActive) {
            // Voting power from staked tokens = staked amount * stake period multiplier
            totalVotingPower += daoMember.stakedAmount * daoMember.stakePeriod;
        }
        
        // Add voting power from earned/pending rewards (1:1, no multiplier)
        uint256 pendingRewards = IUnifiedRewardsTracking(earningsRewardsContract).getPendingRewards(member);
        totalVotingPower += pendingRewards;
        
        return totalVotingPower;
    }
    
    /**
     * @dev Get details of a DAO member
     * @param member Address of the DAO member
     * @return DAOMember struct containing member details
     */
    function getDaoMember(address member) external view returns (
        DAOMember memory
    ) {
        return _daoMembers[member];
    }
    
    /**
     * @dev Get the number of governance actions performed by a member
     * @param member Address of the DAO member
     * @return Number of governance actions
     */
    function getGovernanceActions(address member) external view returns (uint256) {
        // If we're on the same chain as the NativeDAOGovernance, query it directly
        uint64 currentChainId = uint64(block.chainid);
        address nativeDAOAddress = nativeDAOContracts[currentChainId];
        
        if (nativeDAOAddress != address(0)) {
            // If the NativeDAOGovernance contract is on this chain, query it directly
            try INativeDAOGovernance(nativeDAOAddress).getTotalGovernanceActions(member) returns (uint256 actions) {
                return actions;
            } catch {
                // Fallback to local storage if the call fails
                return _governanceActions[member];
            }
        }
        
        // NativeDAOGovernance is not on this chain or we can't reach it
        // Note: We can't do cross-chain view function calls, so we have to use local storage
        // This means getGovernanceActions will only return the locally recorded actions
        // for cross-chain scenarios. To get the full count, a separate cross-chain update
        // mechanism would be needed to sync action counts periodically.
        return _governanceActions[member];
    }
    
    /**
     * @dev Check if an address is an active DAO member
     * @param member Address to check
     * @return True if the address is an active DAO member
     */
    function isActiveMember(address member) external view returns (bool) {
        return _daoMembers[member].isActive;
    }
    
    /**
     * @dev Set the governor address
     * @param _governor Address of the governor contract
     */
    function setGovernor(address _governor) external onlyOwner {
        governor = _governor;
    }
    
    /**
     * @dev Set the Governance Action Tracker contract
     * @param _governanceActionTracker Address of the Governance Action Tracker contract
     */
    function setGovernanceActionTracker(address _governanceActionTracker) external onlyOwner {
        require(_governanceActionTracker != address(0), "Invalid tracker address");
        governanceActionTracker = IGovernanceActionTracker(_governanceActionTracker);
        emit GovernanceActionTrackerSet(_governanceActionTracker);
    }
    
    /**
     * @dev Set the NativeDAOGovernance contract for the current chain
     * This is a convenience function that sets the nativeDAOContracts mapping for the current chain
     * @param _nativeDAOAddress Address of the NativeDAOGovernance contract
     */
    function setCurrentChainNativeDAO(address _nativeDAOAddress) external onlyOwner {
        require(_nativeDAOAddress != address(0), "Invalid Native DAO address");
        uint64 currentChainId = uint64(block.chainid);
        nativeDAOContracts[currentChainId] = _nativeDAOAddress;
        emit CrossChainContractRegistered(currentChainId, CONTRACT_TYPE_NATIVE_DAO, _nativeDAOAddress);
    }
    
    /**
     * @dev Award team tokens to a member
     * @param member Address of the team member
     * @param oneYearAmount Amount of tokens staked for 1 year
     * @param twoYearAmount Amount of tokens staked for 2 years
     * @param threeYearAmount Amount of tokens staked for 3 years
     */
    function assignTeamTokens(
        address member,
        uint256 oneYearAmount,
        uint256 twoYearAmount,
        uint256 threeYearAmount
    ) external onlyOwner {
        require(member != address(0), "Invalid address");
        require(
            oneYearAmount > 0 || twoYearAmount > 0 || threeYearAmount > 0,
            "Must assign some tokens"
        );
        
        // Store team token details
        _teamTokens[member] = TeamTokens({
            oneYear: oneYearAmount,
            twoYear: twoYearAmount,
            threeYear: threeYearAmount,
            oneYearClaimDate: block.timestamp + 365 days,
            twoYearClaimDate: block.timestamp + 730 days,
            threeYearClaimDate: block.timestamp + 1095 days,
            claimedTokens: 0
        });
        
        emit TeamTokensAssigned(member, oneYearAmount, twoYearAmount, threeYearAmount);
    }
    
    /**
     * @dev Get team tokens details for a member
     * @param member Address of the team member
     * @return TeamTokens struct containing team token details
     */
    function getTeamTokens(address member) external view returns (uint256, uint256, uint256) {
        TeamTokens storage teamToken = _teamTokens[member];
        return (teamToken.oneYear, teamToken.twoYear, teamToken.threeYear);
    }
    
    /**
     * @dev Claim available team tokens after vesting period
     * @notice Team members can only claim tokens after vesting period and with sufficient governance actions
     */
    function claimTeamTokens() external nonReentrant {
        TeamTokens storage teamToken = _teamTokens[msg.sender];
        
        require(teamToken.oneYear > 0 || 
                teamToken.twoYear > 0 || 
                teamToken.threeYear > 0, 
                "No team tokens assigned");
        
        // Calculate claimable amount based on vesting schedule
        uint256 totalClaimable = 0;
        
        // One year tokens are available after 1 year cliff
        if (teamToken.oneYear > 0 && block.timestamp >= teamToken.oneYearClaimDate) {
            totalClaimable += teamToken.oneYear;
        }
        
        // Two year tokens are available after 2 year cliff
        if (teamToken.twoYear > 0 && block.timestamp >= teamToken.twoYearClaimDate) {
            totalClaimable += teamToken.twoYear;
        }
        
        // Three year tokens are available after 3 year cliff
        if (teamToken.threeYear > 0 && block.timestamp >= teamToken.threeYearClaimDate) {
            totalClaimable += teamToken.threeYear;
        }
        
        // Subtract already claimed tokens
        totalClaimable -= teamToken.claimedTokens;
        
        require(totalClaimable > 0, "No tokens available to claim");
        
        // Check if member has performed enough governance actions
        uint256 requiredActions = totalClaimable / GOVERNANCE_ACTION_THRESHOLD;
        require(_governanceActions[msg.sender] >= requiredActions, 
                "Insufficient governance actions");
        
        // Update claimed amount
        teamToken.claimedTokens += totalClaimable;
        
        // Transfer tokens to the user
        require(
            IERC20(openWorkToken).transfer(msg.sender, totalClaimable),
            "Token transfer failed"
        );
        
        emit TeamTokensClaimed(msg.sender, totalClaimable);
    }
    
    /**
     * @dev Check if a member can vote in governance based on staked tokens or team tokens
     * @param member Address of the member
     * @return True if the member can vote in governance
     */
    function canVoteInGovernance(address member) external view returns (bool) {
        // Log member address to help with debug (will only appear in events when state-changing calls are made)
        
        // Check if active DAO member with staked tokens
        if (_daoMembers[member].isActive) {
            return true;
        }
        
        // Check if has sufficient team tokens (minimum 100,000 tokens)
        TeamTokens memory teamToken = _teamTokens[member];
        uint256 totalTeamTokens = teamToken.oneYear + teamToken.twoYear + teamToken.threeYear;
        if (totalTeamTokens >= MIN_TEAM_TOKENS_FOR_VOTING) {
            return true;
        }
        
        // Check if has sufficient earned tokens (minimum 100,000 tokens)
        uint256 pendingRewards = IUnifiedRewardsTracking(earningsRewardsContract).getPendingRewards(member);
        if (pendingRewards >= MIN_TEAM_TOKENS_FOR_VOTING) {
            return true;
        }
        
        /* FOR TESTING ONLY: Allow all accounts to vote on disputes
        // Remove this line in production! */
        // return true;
        
        // Original behavior - use this for production
        return false;
    }
    
    /**
     * @dev Register an official OpenWork contract
     * @param chainId The chain ID where the contract is deployed
     * @param contractType The type of contract (from CONTRACT_TYPE_* constants)
     * @param contractAddress The address of the contract
     * @param contractName A descriptive name for the contract
     * @return success True if the contract was registered successfully
     */
    function registerOriginalContract(
        uint64 chainId,
        uint8 contractType,
        address contractAddress,
        string memory contractName
    ) external override onlyOwner returns (bool success) {
        require(contractAddress != address(0), "Invalid contract address");
        require(contractType >= CONTRACT_TYPE_JOB_MARKETPLACE && 
                contractType <= CONTRACT_TYPE_REWARDS, 
                "Invalid contract type");
        
        // Store the contract in the mapping
        originalContracts[chainId][contractType] = OriginalContract({
            contractAddress: contractAddress,
            isActive: true,
            contractName: contractName
        });
        
        emit OriginalContractRegistered(chainId, contractType, contractAddress, contractName);
        
        return true;
    }
    
    /**
     * @dev Get an official OpenWork contract address
     * @param chainId The chain ID of the contract
     * @param contractType The type of contract to retrieve
     * @return The contract address, whether it's active, and its name
     */
    function getOriginalContract(uint64 chainId, uint8 contractType) 
        external view override returns (address, bool, string memory) {
        OriginalContract memory contract_ = originalContracts[chainId][contractType];
        return (contract_.contractAddress, contract_.isActive, contract_.contractName);
    }
    
    /**
     * @dev Set the active status of an official OpenWork contract
     * @param chainId The chain ID of the contract
     * @param contractType The type of contract
     * @param isActive Whether the contract should be active
     */
    function setOriginalContractStatus(
        uint64 chainId,
        uint8 contractType,
        bool isActive
    ) external override onlyOwner {
        require(originalContracts[chainId][contractType].contractAddress != address(0), 
                "Contract not registered");
        
        originalContracts[chainId][contractType].isActive = isActive;
    }
    
    // Mapping to track verified skills
    mapping(address => mapping(uint256 => string)) private _verifiedSkills;
    mapping(address => string[]) private _userSkills;
    
    /**
     * @dev Register a verified skill for a user
     * @param user The user ID who has the skill verified (converted from address)
     * @param skillId The ID of the skill
     * @param skillName The name of the skill
     * @return success True if the skill was registered successfully
     */
    function registerVerifiedSkill(
        uint256 user,
        uint256 skillId,
        string memory skillName
    ) external onlyAuthorized returns (bool success) {
        // Convert uint256 back to address
        address userAddress = address(uint160(user));
        
        // Store the verified skill
        _verifiedSkills[userAddress][skillId] = skillName;
        
        // Add to user's skill list if not already present
        bool skillExists = false;
        for (uint i = 0; i < _userSkills[userAddress].length; i++) {
            if (keccak256(bytes(_userSkills[userAddress][i])) == keccak256(bytes(skillName))) {
                skillExists = true;
                break;
            }
        }
        
        if (!skillExists) {
            _userSkills[userAddress].push(skillName);
        }
        
        // No need to emit an event here, but could be added if required
        
        return true;
    }
    
    /**
     * @dev Get verified skills for a user
     * @param user The user address
     * @return skills Array of verified skill names
     */
    function getVerifiedSkills(address user) external view returns (string[] memory) {
        return _userSkills[user];
    }
    
    // _authorizeUpgrade implementation moved to the end of the contract
    
    /**
     * @dev Register a verified skill oracle for the DAO
     * @param skillName Name of the skill to register
     * @return True if the skill oracle was registered successfully
     */
    function registerVerifiedSkill(string memory skillName) external returns (bool) {
        require(bytes(skillName).length > 0, "Skill name cannot be empty");
        
        // In a real implementation, this would have additional checks:
        // - Verify the caller has permission to register skills
        // - Check if skill already exists
        // - Add the skill to a mapping of registered skills
        
        // For now, just return true as placeholder
        return true;
    }
    
    /**
     * @dev Request confiscation of a member's tokens due to violation
     * @param member Address of the member whose tokens should be confiscated
     * @return True if the confiscation request was successful
     */
    function requestConfiscation(address member) external returns (bool) {
        require(member != address(0), "Invalid address");
        require(_daoMembers[member].isActive || 
                _teamTokens[member].oneYear > 0 || 
                _teamTokens[member].twoYear > 0 || 
                _teamTokens[member].threeYear > 0, 
                "Not a DAO member or team token holder");
        
        // Logic for requesting confiscation would go here
        // For now, just return true as placeholder
        return true;
    }
    
    /**
     * @dev Execute confiscation of a member's tokens after approved
     * @param member Address of the member whose tokens should be confiscated
     * @return True if the confiscation was executed successfully
     */
    function executeConfiscation(address member) external returns (bool) {
        require(member != address(0), "Invalid address");
        require(_daoMembers[member].isActive || 
                _teamTokens[member].oneYear > 0 || 
                _teamTokens[member].twoYear > 0 || 
                _teamTokens[member].threeYear > 0, 
                "Not a DAO member or team token holder");
        
        // Logic for executing confiscation would go here
        // For now, just return true as placeholder
        return true;
    }
    
    /**
     * @dev Register a cross-chain contract (Native DAO or Local OpenWork)
     * @param chainId The destination chain ID (LayerZero chain ID)
     * @param contractType Type of contract (1 = Native DAO, 2 = Local OpenWork)
     * @param contractAddress Address of the contract on the destination chain
     * @return success True if the contract was registered successfully
     */
    function registerCrossChainContract(
        uint64 chainId,
        uint8 contractType,
        address contractAddress
    ) external onlyOwner returns (bool success) {
        require(contractAddress != address(0), "Invalid contract address");
        require(contractType == CONTRACT_TYPE_NATIVE_DAO || 
                contractType == CONTRACT_TYPE_LOCAL_OPENWORK, 
                "Invalid contract type");
        
        // Store the contract address based on type
        if (contractType == CONTRACT_TYPE_NATIVE_DAO) {
            nativeDAOContracts[chainId] = contractAddress;
        } else if (contractType == CONTRACT_TYPE_LOCAL_OPENWORK) {
            localOpenWorkContracts[chainId] = contractAddress;
        }
        
        // Also register as trusted receiver in the bridge
        IOpenWorkBridge(layerZeroBridge).setTrustedReceiver(
            uint16(chainId),
            contractAddress,
            true
        );
        
        emit CrossChainContractRegistered(chainId, contractType, contractAddress);
        return true;
    }
    
    /**
     * @dev Send a cross-chain message to a registered contract
     * @param chainId The destination chain ID (LayerZero chain ID)
     * @param contractType Type of contract to send to (1 = Native DAO, 2 = Local OpenWork)
     * @param message The message data to send
     * @return messageId Unique ID of the sent message
     */
    function sendCrossChainMessage(
        uint64 chainId,
        uint8 contractType,
        bytes memory message
    ) public payable onlyAuthorized returns (bytes32 messageId) {
        address targetContract;
        
        // Get the target contract address based on type
        if (contractType == CONTRACT_TYPE_NATIVE_DAO) {
            targetContract = nativeDAOContracts[chainId];
        } else if (contractType == CONTRACT_TYPE_LOCAL_OPENWORK) {
            targetContract = localOpenWorkContracts[chainId];
        } else {
            revert("Invalid contract type");
        }
        
        require(targetContract != address(0), "Contract not registered");
        
        // Calculate the fee needed for the message
        uint256 fee = IOpenWorkBridge(layerZeroBridge).estimateFee(
            uint16(chainId),
            targetContract,
            message
        );
        
        require(msg.value >= fee, "Insufficient fee provided");
        
        // Send the message through the bridge
        messageId = IOpenWorkBridge(layerZeroBridge).sendMessage{value: msg.value}(
            uint16(chainId),
            targetContract,
            message
        );
        
        emit CrossChainMessageSent(chainId, messageId);
        return messageId;
    }
    
    /**
     * @dev Called when a cross-chain message is received from the bridge
     * @param srcChainId The source chain ID
     * @param sender The sender address on the source chain
     * @param message The message data
     * @return success Whether the message was successfully processed
     */
    function receiveCrossChainMessage(
        uint16 srcChainId,
        address sender,
        bytes calldata message
    ) external override returns (bool success) {
        // Ensure the message is from the bridge
        require(msg.sender == layerZeroBridge, "Only bridge can call");
        
        // Verify sender is a registered contract
        require(
            sender == nativeDAOContracts[uint64(srcChainId)] || 
            sender == localOpenWorkContracts[uint64(srcChainId)],
            "Sender not registered"
        );
        
        // Process the message based on its type
        // In this implementation, we'll parse the first byte as a message type identifier
        if (message.length > 0) {
            uint8 messageType = uint8(message[0]);
            
            // Handle different message types
            if (messageType == MESSAGE_TYPE_VERIFY_SKILL) {
                // Handle VerifySkill message
                _handleVerifySkillMessage(sender, message[1:]);
            } else if (messageType == MESSAGE_TYPE_MEMBER_VERIFICATION) {
                // Handle DAOMemberVerification message
                _handleMemberVerificationMessage(sender, srcChainId, message[1:]);
            } else if (messageType == MESSAGE_TYPE_DISPUTE_ESCALATION) {
                // Handle DisputeEscalation message
                _handleDisputeEscalationMessage(sender, message[1:]);
            } else if (messageType == MESSAGE_TYPE_CONTRACT_UPGRADE) {
                // Handle Contract Upgrade message
                _handleContractUpgradeMessage(sender, message[1:]);
            } else {
                // Unknown message type
                revert("Unknown message type");
            }
        }
        
        return true; // Message was successfully processed
    }
    
    /**
     * @dev Internal function to handle verify skill messages
     * @param sender The sender address
     * @param data The message data
     */
    function _handleVerifySkillMessage(address sender, bytes calldata data) internal {
        // Parse the message data to extract skill verification details
        // Implementation will depend on the exact message format
        
        // For now, we'll use a placeholder implementation
        // In a real implementation, this would verify and register the skill
    }
    
    /**
     * @dev Internal function to handle member verification messages
     * @param sender The sender address
     * @param sourceChainId The source chain ID
     * @param data The message data
     */
    function _handleMemberVerificationMessage(address sender, uint16 sourceChainId, bytes calldata data) internal {
        // Parse the message data to extract member verification request
        // Implementation will depend on the exact message format
        
        // For now, we'll use a placeholder implementation
        // In a real implementation, this would verify member status and send a response
    }
    
    /**
     * @dev Internal function to handle dispute escalation messages
     * @param sender The sender address
     * @param data The message data
     */
    function _handleDisputeEscalationMessage(address sender, bytes calldata data) internal {
        // Parse the message data to extract dispute details
        // Implementation will depend on the exact message format
        
        // For now, we'll use a placeholder implementation
        // In a real implementation, this would escalate a dispute to the main DAO governance
    }
    
    /**
     * @dev Internal function to handle contract upgrade messages
     * @param sender The sender address
     * @param data The message data
     */
    function _handleContractUpgradeMessage(address sender, bytes calldata data) internal {
        // Decode the upgrade message
        // Format: [contractType, newImplementationAddress]
        require(data.length >= 21, "Invalid upgrade message format");
        
        uint8 contractType = uint8(data[0]);
        address newImplementation;
        
        // Extract the address from the message (20 bytes after the contract type)
        assembly {
            newImplementation := mload(add(add(data.offset, 1), 0x20))
        }
        
        require(newImplementation != address(0), "Invalid implementation address");
        
        // Get the proxy address for this contract type on this chain
        address proxyAddress = originalContracts[uint64(block.chainid)][contractType].contractAddress;
        require(proxyAddress != address(0), "Contract not registered");
        
        // Use the proxy's upgradeTo function to upgrade the implementation
        (bool success, ) = proxyAddress.call(
            abi.encodeWithSignature("upgradeTo(address)", newImplementation)
        );
        require(success, "Upgrade failed");
        
        emit ContractUpgraded(uint64(block.chainid), contractType, newImplementation);
    }
    
    /**
     * @dev Upgrade a contract on a specific chain
     * @param chainId The chain ID where the contract exists
     * @param contractType The type of contract to upgrade
     * @param newImplementation The address of the new implementation
     * @return The ID of the cross-chain message
     */
    function upgradeContract(
        uint64 chainId,
        uint8 contractType,
        address newImplementation
    ) external override onlyAuthorized returns (bytes32) {
        require(newImplementation != address(0), "Invalid implementation address");
        require(chainId != 0, "Invalid chain ID");
        require(chainId != uint64(block.chainid), "Use upgradeLocalContract for local chain");
        require(contractType >= CONTRACT_TYPE_JOB_MARKETPLACE && 
                contractType <= CONTRACT_TYPE_REWARDS, 
                "Invalid contract type");
        
        // Check if contract is registered on the target chain
        require(originalContracts[chainId][contractType].contractAddress != address(0), 
                "Contract not registered on target chain");
        
        // Prepare the upgrade message
        bytes memory upgradeMessage = new bytes(21);
        
        // First byte is the message type
        upgradeMessage[0] = bytes1(MESSAGE_TYPE_CONTRACT_UPGRADE);
        
        // Second byte is the contract type
        upgradeMessage[1] = bytes1(contractType);
        
        // Next 20 bytes are the new implementation address
        for (uint i = 0; i < 20; i++) {
            upgradeMessage[i + 2] = bytes1(uint8(uint(uint160(newImplementation)) / (2**(8 * (19 - i)))));
        }
        
        // Send the cross-chain message to the DAO on the target chain
        bytes32 messageId = sendCrossChainMessage(
            chainId,
            CONTRACT_TYPE_NATIVE_DAO,
            upgradeMessage
        );
        
        return messageId;
    }
    
    /**
     * @dev Upgrade a contract on the local chain
     * @param contractType The type of contract to upgrade
     * @param newImplementation The address of the new implementation
     * @return success True if the upgrade was successful
     */
    function upgradeLocalContract(
        uint8 contractType,
        address newImplementation
    ) external override onlyAuthorized returns (bool) {
        require(newImplementation != address(0), "Invalid implementation address");
        require(contractType >= CONTRACT_TYPE_JOB_MARKETPLACE && 
                contractType <= CONTRACT_TYPE_REWARDS, 
                "Invalid contract type");
        
        // Get the proxy address for this contract type on this chain
        address proxyAddress = originalContracts[uint64(block.chainid)][contractType].contractAddress;
        require(proxyAddress != address(0), "Contract not registered");
        
        // Use the proxy's upgradeTo function to upgrade the implementation
        (bool success, ) = proxyAddress.call(
            abi.encodeWithSignature("upgradeTo(address)", newImplementation)
        );
        require(success, "Upgrade failed");
        
        emit ContractUpgraded(uint64(block.chainid), contractType, newImplementation);
        
        return true;
    }
    
    /**
     * @dev Override for the _authorizeUpgrade function
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Allow the deployer (owner) to upgrade this contract
    }
}
