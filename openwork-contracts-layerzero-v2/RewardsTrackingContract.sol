// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/ERC1967/ERC1967UpgradeUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./interfaces/IUnifiedRewardsTracking.sol";
import "./interfaces/ICrossChainBridge.sol";
import "./interfaces/IGovernanceActionTracker.sol";

/**
 * @title RewardsTrackingContractUSDT
 * @dev Contract for tracking job completions and calculating rewards based on job value bands
 * Deployed on Optimism for tracking rewards that will be paid out on Ethereum
 * Now supports UUPS Upgradeable pattern
 */
contract RewardsTrackingContractUSDT is 
    Initializable,
    IUnifiedRewardsTracking, 
    ReentrancyGuardUpgradeable, 
    OwnableUpgradeable, 
    UUPSUpgradeable {
    using Counters for Counters.Counter;

    // Constants
    uint256 constant public DECIMALS = 6; // For USD value

    // State variables
    address public crossChainBridge;
    address public daoGovernanceContract;
    IGovernanceActionTracker public governanceActionTracker;
    
    // Reward band counter
    Counters.Counter internal bandCounter;
    
    // Data structures
    struct UserRewards {
        uint256 pendingAmount;
        uint256 claimedAmount;
        uint256 totalJobsCompleted;
        uint256 lastJobTimestamp;
        uint256 lastClaimTimestamp;
    }
    
    struct RewardBand {
        uint256 minJobValue;
        uint256 maxJobValue;
        uint256 rewardAmount;
    }
    
    // Mappings
    mapping(address => UserRewards) public userRewards;
    mapping(bytes32 => bool) public processedJobs;
    mapping(bytes32 => bool) public processedClaims;
    mapping(uint256 => RewardBand) public rewardBands;
    
    // Events
    event RewardBandSet(uint256 bandIndex, uint256 minJobValue, uint256 maxJobValue, uint256 rewardAmount);
    event JobProcessed(bytes32 indexed jobId, address indexed recipient, uint256 jobValue, uint256 rewardsAmount);
    event RewardsClaimed(address indexed user, uint256 amount);
    // Using the interface event instead of redefining it
    // event GovernanceActionRecorded(address indexed user, uint256 weight);
    
    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initialize function for proxy contracts
     * This should be called right after proxy deployment to properly set ownership and contract parameters
     * @param initialOwner The initial owner address for the proxy
     * @param _jobMarketContract The job market contract address that can record completions
     */
    function initialize(address initialOwner, address _jobMarketContract) external initializer {
        require(initialOwner != address(0), "Invalid owner address");
        require(_jobMarketContract != address(0), "Invalid job market address");
        
        // Initialize inherited contracts
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // Set proxy owner
        _transferOwnership(initialOwner);
        
        // Set job market contract
        jobMarketContract = _jobMarketContract;
        
        // Initialize reward bands
        _setRewardBand(0, 0, 100 * (10**DECIMALS), 5 * (10**DECIMALS));                  // Band 1
        _setRewardBand(1, 100 * (10**DECIMALS), 300 * (10**DECIMALS), 15 * (10**DECIMALS));      // Band 2
        _setRewardBand(2, 300 * (10**DECIMALS), 500 * (10**DECIMALS), 25 * (10**DECIMALS));      // Band 3
        _setRewardBand(3, 500 * (10**DECIMALS), 1000 * (10**DECIMALS), 50 * (10**DECIMALS));     // Band 4
        _setRewardBand(4, 1000 * (10**DECIMALS), 1500 * (10**DECIMALS), 75 * (10**DECIMALS));    // Band 5
        _setRewardBand(5, 1500 * (10**DECIMALS), 2000 * (10**DECIMALS), 100 * (10**DECIMALS));   // Band 6
        _setRewardBand(6, 2000 * (10**DECIMALS), 2500 * (10**DECIMALS), 125 * (10**DECIMALS));   // Band 7
        _setRewardBand(7, 2500 * (10**DECIMALS), 3000 * (10**DECIMALS), 150 * (10**DECIMALS));   // Band 8
        _setRewardBand(8, 3000 * (10**DECIMALS), 4000 * (10**DECIMALS), 200 * (10**DECIMALS));   // Band 9
        _setRewardBand(9, 4000 * (10**DECIMALS), 5000 * (10**DECIMALS), 250 * (10**DECIMALS));   // Band 10
        _setRewardBand(10, 5000 * (10**DECIMALS), 6000 * (10**DECIMALS), 300 * (10**DECIMALS));  // Band 11
        _setRewardBand(11, 6000 * (10**DECIMALS), 7000 * (10**DECIMALS), 350 * (10**DECIMALS));  // Band 12
        _setRewardBand(12, 7000 * (10**DECIMALS), 8000 * (10**DECIMALS), 400 * (10**DECIMALS));  // Band 13
        _setRewardBand(13, 8000 * (10**DECIMALS), 9000 * (10**DECIMALS), 450 * (10**DECIMALS));  // Band 14
        _setRewardBand(14, 9000 * (10**DECIMALS), 10000 * (10**DECIMALS), 500 * (10**DECIMALS)); // Band 15
        _setRewardBand(15, 10000 * (10**DECIMALS), 15000 * (10**DECIMALS), 750 * (10**DECIMALS)); // Band 16
        _setRewardBand(16, 15000 * (10**DECIMALS), 20000 * (10**DECIMALS), 1000 * (10**DECIMALS)); // Band 17
        _setRewardBand(17, 20000 * (10**DECIMALS), 30000 * (10**DECIMALS), 1500 * (10**DECIMALS)); // Band 18
        _setRewardBand(18, 30000 * (10**DECIMALS), 50000 * (10**DECIMALS), 2500 * (10**DECIMALS)); // Band 19
        _setRewardBand(19, 50000 * (10**DECIMALS), 2**256 - 1, 4000 * (10**DECIMALS));       // Band 20
    }
    
    /**
     * @dev Records a job completion and calculates rewards
     * @param jobId Unique identifier for the job
     * @param jobValue The value of the job in USD (6 decimals)
     * @param recipient Address that will receive the rewards
     * @return rewardsAmount The amount of rewards calculated for this job
     */
    function recordJobCompletion(
        bytes32 jobId,
        uint256 jobValue,
        address recipient
    ) external override nonReentrant returns (uint256 rewardsAmount) {
        require(msg.sender == jobMarketContract, "Only JobMarket contract can call");
        require(!processedJobs[jobId], "Job already processed");
        require(recipient != address(0), "Invalid recipient");
        
        // Calculate rewards based on job value
        rewardsAmount = calculateRewardAmount(jobValue);
        
        // Update user rewards data
        UserRewards storage rewards = userRewards[recipient];
        rewards.pendingAmount += rewardsAmount;
        rewards.totalJobsCompleted += 1;
        rewards.lastJobTimestamp = block.timestamp;
        
        // Mark job as processed
        processedJobs[jobId] = true;
        
        emit JobProcessed(jobId, recipient, jobValue, rewardsAmount);
        
        return rewardsAmount;
    }
    
    /**
     * @dev Claims rewards for the caller
     * Implementation of IUnifiedRewardsTracking.claimRewards()
     */
    function claimRewards() external override nonReentrant {
        address user = msg.sender;
        UserRewards storage rewards = userRewards[user];
        
        uint256 totalJobValue = rewards.pendingAmount;
        require(totalJobValue > 0, "No rewards to claim");
        
        // Reset pending rewards and update claimed amount
        rewards.pendingAmount = 0;
        rewards.claimedAmount += totalJobValue;
        rewards.lastClaimTimestamp = block.timestamp;
        
        // Only process cross-chain claim if bridge is set
        if (crossChainBridge != address(0)) {
            // Encode the payload for cross-chain message - send job value instead of token amount
            bytes memory payload = abi.encode(user, totalJobValue);
            
            // Send message via bridge
            bytes32 messageId = ICrossChainBridge(crossChainBridge).sendMessage(payload);
            
            // Record the claim as processed
            processedClaims[messageId] = true;
        }
        
        // Emit event for the claim
        emit RewardsClaimed(user, totalJobValue);
        
        // Credit governance action for claiming
        _recordGovernanceAction(user, totalJobValue / 10); // 10% of claimed value as governance weight
    }
    
    /**
     * @dev Returns the amount of pending rewards for a user
     * @param user The address to check
     * @return The amount of pending rewards
     */
    function getPendingRewards(address user) external view override returns (uint256) {
        return userRewards[user].pendingAmount;
    }
    
    /**
     * @dev Returns the amount of claimed rewards for a user
     * @param user The address to check
     * @return The amount of claimed rewards
     */
    function getClaimedRewards(address user) external view override returns (uint256) {
        return userRewards[user].claimedAmount;
    }
    
    /**
     * @dev Adds a user to the claim allowlist with a specific amount (unused in this implementation)
     * @param user The address to add to the allowlist
     * @param amount The amount to allow
     * @return success Whether the operation was successful
     */
    function addToClaimAllowlist(address user, uint256 amount) external pure override returns (bool) {
        // Suppress unused parameter warnings by referencing them
        if (user != address(0) && amount > 0) {
            // No actual logic needed, this is just to use the parameters
        }
        
        // This is implemented for interface compatibility but not used in this contract
        return true;
    }
    
    /**
     * @dev Calculates the reward amount based on job value
     * @param jobValue The value of the job in USD (6 decimals)
     * @return The calculated reward amount
     */
    function calculateRewardAmount(uint256 jobValue) public view returns (uint256) {
        for (uint256 i = 0; i < bandCounter._value; i++) {
            RewardBand memory band = rewardBands[i];
            if (jobValue >= band.minJobValue && jobValue < band.maxJobValue) {
                return band.rewardAmount;
            }
        }
        
        // If no band found, return 0
        return 0;
    }
    
    /**
     * @dev Updates a reward band configuration
     * @param bandIndex The index of the band to update
     * @param minJobValue The minimum job value for this band
     * @param maxJobValue The maximum job value for this band
     * @param rewardAmount The reward amount for this band
     */
    function updateRewardBand(
        uint256 bandIndex,
        uint256 minJobValue,
        uint256 maxJobValue,
        uint256 rewardAmount
    ) external onlyOwner {
        require(bandIndex < bandCounter._value, "Invalid band index");
        require(minJobValue < maxJobValue, "Min must be less than max");
        
        _setRewardBand(bandIndex, minJobValue, maxJobValue, rewardAmount);
    }
    
    /**
     * @dev Set or update a reward band
     * @param bandIndex The index of the band
     * @param minJobValue The minimum job value for this band
     * @param maxJobValue The maximum job value for this band
     * @param rewardAmount The reward amount for this band
     */
    function _setRewardBand(
        uint256 bandIndex,
        uint256 minJobValue,
        uint256 maxJobValue,
        uint256 rewardAmount
    ) internal {
        if (bandIndex >= bandCounter._value) {
            bandCounter.increment();
        }
        
        rewardBands[bandIndex] = RewardBand({
            minJobValue: minJobValue,
            maxJobValue: maxJobValue,
            rewardAmount: rewardAmount
        });
        
        emit RewardBandSet(bandIndex, minJobValue, maxJobValue, rewardAmount);
    }
    
    /**
     * @dev Records a governance action for a user
     * @param user The address of the user
     * @param weight The weight of the action
     */
    function _recordGovernanceAction(address user, uint256 weight) internal {
        // First try the new GovernanceActionTracker
        if (address(governanceActionTracker) != address(0)) {
            try governanceActionTracker.recordGovernanceActionWithWeight(user, weight) {
                // Action recorded successfully in the dedicated tracker
                emit GovernanceActionRecorded(user, weight);
                return; // No need to try other methods
            } catch {
                // Continue with legacy methods if this fails
            }
        }
        
        // Fall back to the old DAO governance contract if tracker is not set
        if (daoGovernanceContract != address(0)) {
            // Call the DAO governance contract to record this action
            // Note: We're dropping the weight parameter as per old standardized interface
            
            (bool success, ) = daoGovernanceContract.call(
                abi.encodeWithSignature("recordGovernanceAction(address)", user)
            );
            
            if (success) {
                emit GovernanceActionRecorded(user, weight);
            }
        } else {
            // Still emit the event even if we don't have a contract to call
            emit GovernanceActionRecorded(user, weight);
        }
    }
    
    // Removed setNativeOpenWorkContract function as it's no longer needed
    
    /**
     * @dev Updates the cross-chain bridge address
     * @param _crossChainBridge The new address
     */
    function setCrossChainBridge(address _crossChainBridge) external onlyOwner {
        require(_crossChainBridge != address(0), "Invalid address");
        crossChainBridge = _crossChainBridge;
    }
    
    /**
     * @dev Updates the DAO governance contract address
     * @param _daoGovernanceContract The new address
     */
    function setDAOGovernanceContract(address _daoGovernanceContract) external onlyOwner {
        require(_daoGovernanceContract != address(0), "Invalid address");
        daoGovernanceContract = _daoGovernanceContract;
    }
    
    /**
     * @dev Sets the Governance Action Tracker contract address
     * @param _governanceActionTracker The new address
     */
    function setGovernanceActionTracker(address _governanceActionTracker) external onlyOwner {
        require(_governanceActionTracker != address(0), "Invalid address");
        governanceActionTracker = IGovernanceActionTracker(_governanceActionTracker);
    }
    
    /**
     * @dev Gets user total stats
     * @param user The address to check
     * @return totalJobs Total jobs completed by the user
     * @return totalPending Total pending rewards
     * @return totalClaimed Total claimed rewards
     */
    function getUserStats(address user) external view returns (uint256 totalJobs, uint256 totalPending, uint256 totalClaimed) {
        UserRewards memory rewards = userRewards[user];
        return (rewards.totalJobsCompleted, rewards.pendingAmount, rewards.claimedAmount);
    }
    
    // This function is now properly defined in the top section of the contract
    
    // Intentionally left empty - relying on UUPSUpgradeable's functions
    // which have onlyProxy modifiers but use _authorizeUpgrade with our implementation (onlyOwner)

    /**
     * @dev Required by the UUPS pattern - only owner can upgrade the implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // The authorization is handled by the onlyOwner modifier
    }
    
    // Implement missing required functions from IUnifiedRewardsTracking
    
    /**
     * @dev Calculate token reward based on job value
     * @param jobValue USD value of the job
     * @return Amount of tokens to be rewarded
     */
    function calculateTokenReward(uint256 jobValue) external view override returns (uint256) {
        return calculateRewardAmount(jobValue);
    }
    
    /**
     * @dev Get total staked tokens for a user
     * @param user Address of the user
     * @return Total staked tokens
     */
    function getTotalStakedTokens(address user) external pure override returns (uint256) {
        // Suppress unused parameter warning by referencing it
        if (user != address(0)) {
            // No actual logic, just preventing compiler warning
        }
        
        // Not implemented in this version - return 0
        return 0;
    }
    
    /**
     * @dev Check if user has completed governance actions for a level
     * @param user Address of the user
     * @param level Governance level
     * @return Whether user has completed required actions
     */
    function hasCompletedGovernanceActions(address user, uint256 level) external view override returns (bool) {
        // Simplified implementation - can be extended later
        return userRewards[user].totalJobsCompleted > level;
    }
    
    // JobMarket contract reference
    address public jobMarketContract;
    
    /**
     * @dev Sets the JobMarket contract address
     * @param _jobMarketContract The new JobMarket contract address
     */
    function setJobMarketContract(address _jobMarketContract) external onlyOwner {
        require(_jobMarketContract != address(0), "Invalid address");
        jobMarketContract = _jobMarketContract;
    }
    
    /**
     * @dev Record earnings for a user - from IEarningsRewardsContract
     * @param user Address of the user
     * @param amount Amount of earnings to record
     */
    function recordEarnings(address user, uint256 amount) external override {
        require(
            msg.sender == jobMarketContract,
            "Only JobMarket contract can call"
        );
        require(user != address(0), "Invalid user address");
        
        // Update user rewards
        UserRewards storage rewards = userRewards[user];
        rewards.pendingAmount += amount;
        
        emit UnifiedRewardsEarned(user, amount);
    }
    
    /**
     * @dev Record a governance action
     * @param user Address of the user
     * @param actionWeight Weight of the action
     */
    function recordGovernanceAction(address user, uint256 actionWeight) external override {
        require(msg.sender == jobMarketContract || msg.sender == daoGovernanceContract, 
                "Only authorized contracts can call");
        
        _recordGovernanceAction(user, actionWeight);
    }
    
    /**
     * @dev Stake tokens
     * @param amount Amount to stake
     * @param duration Duration in days
     */
    function stakeTokens(uint256 amount, uint256 duration) external pure override {
        // Suppress unused parameter warnings by referencing them
        if (amount > 0 && duration > 0) {
            // No actual logic needed, this is just to use the parameters
        }
        
        // Not implemented in this contract version
        revert("Staking not implemented in this contract");
    }
    
    /**
     * @dev Unstake tokens
     * @param stakeIndex Index of the stake to unstake
     */
    function unstakeTokens(uint256 stakeIndex) external pure override {
        // Suppress unused parameter warning by referencing it
        if (stakeIndex > 0) {
            // No actual logic needed, this is just to use the parameter
        }
        
        // Not implemented in this contract version
        revert("Staking not implemented in this contract");
    }
}