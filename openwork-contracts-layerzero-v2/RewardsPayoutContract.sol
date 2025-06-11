// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IBridgeMessageReceiver.sol";

/**
 * @title RewardsPayoutContractUSDTUpgradeable
 * @dev Contract for paying out USDT rewards, deployed on Ethereum mainnet
 * Receives cross-chain messages from the rewards tracking contract on Optimism
 * Upgradeable using the UUPS pattern
 */
contract RewardsPayoutContractUSDTUpgradeable is 
    IBridgeMessageReceiver, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable, 
    OwnableUpgradeable,
    UUPSUpgradeable 
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // State variables
    address public rewardsToken;       // OpenWork token address (on ETH Sepolia)
    address public crossChainBridge;   // Cross-chain bridge address
    uint16 public sourceChainId;       // Chain ID for the source chain (Optimism)
    address public sourceAddress;      // Address of the rewards tracking contract on Optimism
    address public governanceActionTracker; // Governance action tracker contract address

    // Constants for staking
    uint256 public constant STAKING_PERIOD = 365 days;  // 1 year staking period
    uint256 public constant TOKENS_PER_GOVERNANCE_ACTION = 10000 * 10**18;  // 10,000 tokens per governance action

    // Reward band data structures
    struct RewardBand {
        uint256 minJobValue;  // Minimum job value in USD (6 decimals)
        uint256 maxJobValue;  // Maximum job value in USD (6 decimals)
        uint256 tokensPerDollar;  // Tokens per dollar for this band (18 decimals)
        uint256 tokensMinted;  // Total tokens minted in this band
        uint256 tokenLimit;  // Maximum tokens for this band (50M)
    }

    // Data structures
    struct ClaimData {
        uint256 pendingAmount;        // Amount waiting to be claimed
        uint256 totalClaimed;         // Total amount claimed so far
        uint256 lastClaimTime;        // Timestamp of last claim
    }

    struct StakedReward {
        uint256 amount;               // Amount of tokens staked
        uint256 stakingDate;          // When the tokens were staked
        uint256 maturityDate;         // When the tokens mature (stakingDate + 1 year)
        uint256 requiredGovernanceActions; // Number of governance actions required to unlock
        uint256 completedGovernanceActions; // Number of governance actions completed
        bool unlocked;                // Whether the tokens have been unlocked
        bool claimed;                 // Whether the tokens have been claimed
    }

    // Mappings
    mapping(address => ClaimData) public userClaims;
    mapping(address => StakedReward[]) public userStakedRewards;
    mapping(address => uint256) public userGovernanceActions;
    mapping(bytes32 => bool) public processedMessages;
    mapping(uint256 => RewardBand) public rewardBands;

    // Band counter
    uint256 public currentBandIndex;
    uint256 public totalTokensMinted;

    // Events
    event ClaimApproved(address indexed recipient, uint256 amount);
    event RewardsPaid(address indexed recipient, uint256 amount);
    event BridgeUpdated(address indexed newBridge);
    event SourceUpdated(uint16 chainId, address indexed sourceAddress);
    event RewardBandUpdated(uint256 bandIndex, uint256 minJobValue, uint256 maxJobValue, uint256 tokensPerDollar);
    event TokensAutoStaked(address indexed user, uint256 amount, uint256 maturityDate, uint256 requiredActions);
    event GovernanceActionRecorded(address indexed user, uint256 actionCount, uint256 totalActions);
    event StakedRewardUnlocked(address indexed user, uint256 stakeIndex, uint256 amount);
    event RewardsTokenUpdated(address indexed newRewardsToken);
    event GovernanceActionTrackerUpdated(address indexed newGovernanceActionTracker);
    event RewardBandsInitialized();

    /**
     * @dev Initializes the contract (replaces constructor in upgradeable contracts)
     * @param _initialOwner Address of the initial owner
     */
    function initialize(address _initialOwner) public initializer {
        __Pausable_init();
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_initialOwner != address(0), "Invalid initial owner address");

        // Transfer ownership to the specified initial owner
        _transferOwnership(_initialOwner);

        // Initialize the rewards bands based on updated-rewards-bands.md
        uint256 bandTokenLimit = 50000000 * 10**18; // 50M tokens per band

        // Initialize all 20 reward bands with decreasing tokens per dollar
        _setRewardBand(0, 0, 500 * 10**6, 100000 * 10**18, bandTokenLimit);                    // Band 1: 0-$500
        _setRewardBand(1, 500 * 10**6, 1000 * 10**6, 50000 * 10**18, bandTokenLimit);          // Band 2: $500-$1K
        _setRewardBand(2, 1000 * 10**6, 2000 * 10**6, 25000 * 10**18, bandTokenLimit);         // Band 3: $1K-$2K
        _setRewardBand(3, 2000 * 10**6, 4000 * 10**6, 12500 * 10**18, bandTokenLimit);         // Band 4: $2K-$4K
        _setRewardBand(4, 4000 * 10**6, 8000 * 10**6, 6250 * 10**18, bandTokenLimit);          // Band 5: $4K-$8K
        _setRewardBand(5, 8000 * 10**6, 16000 * 10**6, 3125 * 10**18, bandTokenLimit);         // Band 6: $8K-$16K
        _setRewardBand(6, 16000 * 10**6, 32000 * 10**6, 1562 * 10**18, bandTokenLimit);        // Band 7: $16K-$32K
        _setRewardBand(7, 32000 * 10**6, 64000 * 10**6, 781 * 10**18, bandTokenLimit);         // Band 8: $32K-$64K
        _setRewardBand(8, 64000 * 10**6, 128000 * 10**6, 391 * 10**18, bandTokenLimit);        // Band 9: $64K-$128K
        _setRewardBand(9, 128000 * 10**6, 256000 * 10**6, 195 * 10**18, bandTokenLimit);       // Band 10: $128K-$256K
        _setRewardBand(10, 256000 * 10**6, 512000 * 10**6, 98 * 10**18, bandTokenLimit);       // Band 11: $256K-$512K
        _setRewardBand(11, 512000 * 10**6, 1024000 * 10**6, 49 * 10**18, bandTokenLimit);      // Band 12: $512K-$1.024M
        _setRewardBand(12, 1024000 * 10**6, 2048000 * 10**6, 24 * 10**18, bandTokenLimit);     // Band 13: $1.024M-$2.048M
        _setRewardBand(13, 2048000 * 10**6, 4096000 * 10**6, 12 * 10**18, bandTokenLimit);     // Band 14: $2.048M-$4.096M
        _setRewardBand(14, 4096000 * 10**6, 8192000 * 10**6, 6 * 10**18, bandTokenLimit);      // Band 15: $4.096M-$8.192M
        _setRewardBand(15, 8192000 * 10**6, 16384000 * 10**6, 3 * 10**18, bandTokenLimit);     // Band 16: $8.192M-$16.384M
        _setRewardBand(16, 16384000 * 10**6, 32768000 * 10**6, 15 * 10**17, bandTokenLimit);   // Band 17: $16.384M-$32.768M
        _setRewardBand(17, 32768000 * 10**6, 65536000 * 10**6, 75 * 10**16, bandTokenLimit);   // Band 18: $32.768M-$65.536M
        _setRewardBand(18, 65536000 * 10**6, 131072000 * 10**6, 38 * 10**16, bandTokenLimit);  // Band 19: $65.536M-$131.072M
        _setRewardBand(19, 131072000 * 10**6, 2**256 - 1, 19 * 10**16, bandTokenLimit);        // Band 20: $131.072M+

        currentBandIndex = 0;
        totalTokensMinted = 0;
    }

    /**
     * @dev Set the rewards token address
     * @param _rewardsToken Address of the OpenWork token
     */
    function setRewardsToken(address _rewardsToken) external onlyOwner {
        require(_rewardsToken != address(0), "Invalid rewards token address");
        rewardsToken = _rewardsToken;
        emit RewardsTokenUpdated(_rewardsToken);
    }

    /**
     * @dev Set the cross-chain bridge address
     * @param _crossChainBridge Address of the cross-chain bridge
     */
    function setCrossChainBridge(address _crossChainBridge) external onlyOwner {
        require(_crossChainBridge != address(0), "Invalid bridge address");
        crossChainBridge = _crossChainBridge;
        emit BridgeUpdated(_crossChainBridge);
    }

    /**
     * @dev Set the source chain configuration
     * @param _sourceChainId Chain ID for the source chain
     * @param _sourceAddress Address of the rewards tracking contract on source chain
     */
    function setSourceConfig(uint16 _sourceChainId, address _sourceAddress) external onlyOwner {
        require(_sourceAddress != address(0), "Invalid source address");
        sourceChainId = _sourceChainId;
        sourceAddress = _sourceAddress;
        emit SourceUpdated(_sourceChainId, _sourceAddress);
    }

    /**
     * @dev Set the governance action tracker address
     * @param _governanceActionTracker Address of the governance action tracker
     */
    function setGovernanceActionTracker(address _governanceActionTracker) external onlyOwner {
        require(_governanceActionTracker != address(0), "Invalid governance tracker address");
        governanceActionTracker = _governanceActionTracker;
        emit GovernanceActionTrackerUpdated(_governanceActionTracker);
    }

    /**
     * @dev Initialize the default reward bands (can be called post-deployment)
     * This sets up the 20 reward bands with decreasing tokens per dollar
     */
    function initializeRewardBands() external onlyOwner {
        uint256 bandTokenLimit = 50000000 * 10**18; // 50M tokens per band

        // Initialize all 20 reward bands with decreasing tokens per dollar
        _setRewardBand(0, 0, 500 * 10**6, 100000 * 10**18, bandTokenLimit);                    // Band 1: 0-$500
        _setRewardBand(1, 500 * 10**6, 1000 * 10**6, 50000 * 10**18, bandTokenLimit);          // Band 2: $500-$1K
        _setRewardBand(2, 1000 * 10**6, 2000 * 10**6, 25000 * 10**18, bandTokenLimit);         // Band 3: $1K-$2K
        _setRewardBand(3, 2000 * 10**6, 4000 * 10**6, 12500 * 10**18, bandTokenLimit);         // Band 4: $2K-$4K
        _setRewardBand(4, 4000 * 10**6, 8000 * 10**6, 6250 * 10**18, bandTokenLimit);          // Band 5: $4K-$8K
        _setRewardBand(5, 8000 * 10**6, 16000 * 10**6, 3125 * 10**18, bandTokenLimit);         // Band 6: $8K-$16K
        _setRewardBand(6, 16000 * 10**6, 32000 * 10**6, 1562 * 10**18, bandTokenLimit);        // Band 7: $16K-$32K
        _setRewardBand(7, 32000 * 10**6, 64000 * 10**6, 781 * 10**18, bandTokenLimit);         // Band 8: $32K-$64K
        _setRewardBand(8, 64000 * 10**6, 128000 * 10**6, 391 * 10**18, bandTokenLimit);        // Band 9: $64K-$128K
        _setRewardBand(9, 128000 * 10**6, 256000 * 10**6, 195 * 10**18, bandTokenLimit);       // Band 10: $128K-$256K
        _setRewardBand(10, 256000 * 10**6, 512000 * 10**6, 98 * 10**18, bandTokenLimit);       // Band 11: $256K-$512K
        _setRewardBand(11, 512000 * 10**6, 1024000 * 10**6, 49 * 10**18, bandTokenLimit);      // Band 12: $512K-$1.024M
        _setRewardBand(12, 1024000 * 10**6, 2048000 * 10**6, 24 * 10**18, bandTokenLimit);     // Band 13: $1.024M-$2.048M
        _setRewardBand(13, 2048000 * 10**6, 4096000 * 10**6, 12 * 10**18, bandTokenLimit);     // Band 14: $2.048M-$4.096M
        _setRewardBand(14, 4096000 * 10**6, 8192000 * 10**6, 6 * 10**18, bandTokenLimit);      // Band 15: $4.096M-$8.192M
        _setRewardBand(15, 8192000 * 10**6, 16384000 * 10**6, 3 * 10**18, bandTokenLimit);     // Band 16: $8.192M-$16.384M
        _setRewardBand(16, 16384000 * 10**6, 32768000 * 10**6, 15 * 10**17, bandTokenLimit);   // Band 17: $16.384M-$32.768M
        _setRewardBand(17, 32768000 * 10**6, 65536000 * 10**6, 75 * 10**16, bandTokenLimit);   // Band 18: $32.768M-$65.536M
        _setRewardBand(18, 65536000 * 10**6, 131072000 * 10**6, 38 * 10**16, bandTokenLimit);  // Band 19: $65.536M-$131.072M
        _setRewardBand(19, 131072000 * 10**6, 2**256 - 1, 19 * 10**16, bandTokenLimit);        // Band 20: $131.072M+

        currentBandIndex = 20; // Set to 20 since we initialized all bands
        emit RewardBandsInitialized();
    }

    /**
     * @dev Calculates token reward for a given job value based on the current band
     * @param jobValue The job value in USD (6 decimals)
     * @return tokenAmount The calculated token amount
     */
    function calculateTokenReward(uint256 jobValue) public view returns (uint256 tokenAmount) {
        for (uint256 i = 0; i < currentBandIndex; i++) {
            RewardBand storage band = rewardBands[i];

            if (jobValue >= band.minJobValue && jobValue < band.maxJobValue) {
                // Convert job value to dollars (remove 6 decimals)
                uint256 jobValueInDollars = jobValue / 10**6;

                // Calculate token amount (dollars * tokensPerDollar)
                tokenAmount = jobValueInDollars * band.tokensPerDollar;

                // Check if the band has enough tokens left
                if (band.tokensMinted + tokenAmount > band.tokenLimit) {
                    tokenAmount = band.tokenLimit - band.tokensMinted;
                    // If this band is depleted, we would need to go to the next band
                    // But for simplicity, we just cap the rewards to what's left in this band
                }

                return tokenAmount;
            }
        }

        return 0; // If no band matches, return 0
    }

    /**
     * @dev Receives cross-chain messages from the rewards tracking contract
     * @param srcChainId Chain ID of the source chain
     * @param srcAddress Address of the source contract
     * @param payload Encoded message payload
     * @return success Whether the message was processed successfully
     */
    function receiveCrossChainMessage(
        uint16 srcChainId,
        address srcAddress,
        bytes calldata payload
    ) external override whenNotPaused nonReentrant returns (bool success) {
        require(msg.sender == crossChainBridge, "Only bridge can call");
        require(srcChainId == sourceChainId, "Invalid source chain");
        require(srcAddress == sourceAddress, "Invalid source address");

        bytes32 messageId = keccak256(payload);
        require(!processedMessages[messageId], "Message already processed");

        // Decode the payload - now expecting job value instead of token amount
        (address recipient, uint256 jobValue) = abi.decode(payload, (address, uint256));

        require(recipient != address(0), "Invalid recipient");
        require(jobValue > 0, "Invalid job value");

        // Calculate token amount based on job value and current band
        uint256 tokenAmount = calculateTokenReward(jobValue);

        // Update the band's minted tokens
        for (uint256 i = 0; i < currentBandIndex; i++) {
            RewardBand storage band = rewardBands[i];
            if (jobValue >= band.minJobValue && jobValue < band.maxJobValue) {
                // Update the minted amount, ensuring we don't exceed the limit
                if (band.tokensMinted + tokenAmount <= band.tokenLimit) {
                    band.tokensMinted += tokenAmount;
                } else {
                    tokenAmount = band.tokenLimit - band.tokensMinted;
                    band.tokensMinted = band.tokenLimit;
                }
                break;
            }
        }

        if (tokenAmount > 0) {
            // Auto-stake the tokens
            uint256 maturityDate = block.timestamp + STAKING_PERIOD;
            uint256 requiredActions = tokenAmount / TOKENS_PER_GOVERNANCE_ACTION;
            if (tokenAmount % TOKENS_PER_GOVERNANCE_ACTION > 0) {
                requiredActions += 1; // Round up the required actions
            }

            // Create a new staked reward entry
            userStakedRewards[recipient].push(StakedReward({
                amount: tokenAmount,
                stakingDate: block.timestamp,
                maturityDate: maturityDate,
                requiredGovernanceActions: requiredActions,
                completedGovernanceActions: 0,
                unlocked: false,
                claimed: false
            }));

            // Update total tokens minted
            totalTokensMinted += tokenAmount;

            emit TokensAutoStaked(recipient, tokenAmount, maturityDate, requiredActions);
        }

        // Mark message as processed
        processedMessages[messageId] = true;

        emit ClaimApproved(recipient, tokenAmount);

        return true;
    }

    /**
     * @dev Records a governance action for a user
     * This can only be called by the governance action tracker contract
     * @param user The address of the user
     * @param actionWeight The weight of the governance action
     */
    function recordGovernanceAction(address user, uint256 actionWeight) external {
        require(msg.sender == governanceActionTracker, "Only governance tracker can call");
        require(user != address(0), "Invalid user address");

        // Record the governance action
        userGovernanceActions[user] += actionWeight;

        // Check if any staked rewards can be unlocked
        StakedReward[] storage stakes = userStakedRewards[user];

        for (uint256 i = 0; i < stakes.length; i++) {
            StakedReward storage stake = stakes[i];

            // Skip already unlocked or claimed stakes
            if (stake.unlocked || stake.claimed) {
                continue;
            }

            // Update completed governance actions based on the user's total
            stake.completedGovernanceActions = userGovernanceActions[user];

            // Check if enough governance actions have been completed
            if (stake.completedGovernanceActions >= stake.requiredGovernanceActions) {
                stake.unlocked = true;
                emit StakedRewardUnlocked(user, i, stake.amount);
            }
        }

        emit GovernanceActionRecorded(user, actionWeight, userGovernanceActions[user]);
    }

    /**
     * @dev Claims matured and unlocked staked rewards for the caller
     * @return success Whether the claim was successful
     */
    function claimRewards() external whenNotPaused nonReentrant returns (bool success) {
        address recipient = msg.sender;
        StakedReward[] storage stakes = userStakedRewards[recipient];

        uint256 totalClaimable = 0;

        // First pass: identify claimable stakes
        for (uint256 i = 0; i < stakes.length; i++) {
            StakedReward storage stake = stakes[i];

            // Skip already claimed stakes
            if (stake.claimed) {
                continue;
            }

            // Check if stake is mature AND unlocked
            bool isMature = block.timestamp >= stake.maturityDate;
            if (isMature && stake.unlocked) {
                totalClaimable += stake.amount;
                stake.claimed = true;
            }
        }

        require(totalClaimable > 0, "No claimable rewards");

        // Check token balance
        uint256 contractBalance = IERC20Upgradeable(rewardsToken).balanceOf(address(this));
        require(contractBalance >= totalClaimable, "Insufficient contract balance");

        // Transfer rewards
        IERC20Upgradeable(rewardsToken).safeTransfer(recipient, totalClaimable);

        emit RewardsPaid(recipient, totalClaimable);

        return true;
    }

    /**
     * @dev Get the staking details for a user
     * @param user Address of the user
     * @return amounts Array of staked amounts
     * @return maturityDates Array of maturity dates for each stake
     * @return requiredActions Array of required governance actions for each stake
     * @return completedActions Array of completed governance actions for each stake
     * @return unlocked Array indicating if each stake is unlocked
     * @return claimed Array indicating if each stake has been claimed
     */
    function getUserStakes(address user) external view returns (
        uint256[] memory amounts,
        uint256[] memory maturityDates,
        uint256[] memory requiredActions,
        uint256[] memory completedActions,
        bool[] memory unlocked,
        bool[] memory claimed
    ) {
        StakedReward[] storage stakes = userStakedRewards[user];
        uint256 count = stakes.length;

        amounts = new uint256[](count);
        maturityDates = new uint256[](count);
        requiredActions = new uint256[](count);
        completedActions = new uint256[](count);
        unlocked = new bool[](count);
        claimed = new bool[](count);

        for (uint256 i = 0; i < count; i++) {
            amounts[i] = stakes[i].amount;
            maturityDates[i] = stakes[i].maturityDate;
            requiredActions[i] = stakes[i].requiredGovernanceActions;
            completedActions[i] = stakes[i].completedGovernanceActions;
            unlocked[i] = stakes[i].unlocked;
            claimed[i] = stakes[i].claimed;
        }

        return (amounts, maturityDates, requiredActions, completedActions, unlocked, claimed);
    }

    /**
     * @dev Returns the amount of pending rewards for a user (staked but not claimed)
     * @param user The address to check
     * @return pendingAmount The total amount of pending (staked) rewards
     */
    function getPendingRewards(address user) external view returns (uint256 pendingAmount) {
        StakedReward[] storage stakes = userStakedRewards[user];

        for (uint256 i = 0; i < stakes.length; i++) {
            if (!stakes[i].claimed) {
                pendingAmount += stakes[i].amount;
            }
        }

        return pendingAmount;
    }

    /**
     * @dev Returns the amount of claimed rewards for a user
     * @param user The address to check
     * @return claimedAmount The total amount of claimed rewards
     */
    function getTotalClaimed(address user) external view returns (uint256 claimedAmount) {
        StakedReward[] storage stakes = userStakedRewards[user];

        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].claimed) {
                claimedAmount += stakes[i].amount;
            }
        }

        return claimedAmount;
    }

    /**
     * @dev Returns the user's governance action count
     * @param user The address to check
     * @return The user's governance action count
     */
    function getUserGovernanceActionCount(address user) external view returns (uint256) {
        return userGovernanceActions[user];
    }

    /**
     * @dev Returns the amount of claimable rewards that are unlocked and matured
     * @param user The address to check
     * @return claimableAmount The amount that can be claimed now
     */
    function getClaimableRewards(address user) external view returns (uint256 claimableAmount) {
        StakedReward[] storage stakes = userStakedRewards[user];

        for (uint256 i = 0; i < stakes.length; i++) {
            StakedReward storage stake = stakes[i];

            if (!stake.claimed && stake.unlocked && block.timestamp >= stake.maturityDate) {
                claimableAmount += stake.amount;
            }
        }

        return claimableAmount;
    }



    /**
     * @dev Pauses the contract, preventing claim approvals and payouts
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses the contract, enabling claim approvals and payouts
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Withdraws any ERC20 tokens stuck in the contract (emergency use)
     * @param tokenAddress The address of the ERC20 token
     * @param amount The amount to withdraw
     */
    function withdrawERC20(address tokenAddress, uint256 amount) external onlyOwner {
        IERC20Upgradeable(tokenAddress).safeTransfer(owner(), amount);
    }

    /**
     * @dev Function that should revert when msg.sender is not authorized to upgrade the contract
     * @param newImplementation The address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Internal function to set or update a reward band
     * @param bandIndex Index of the band to set
     * @param minJobValue Minimum USD value for jobs in this band (6 decimals)
     * @param maxJobValue Maximum USD value for jobs in this band (6 decimals)
     * @param tokensPerDollar Tokens awarded per dollar in this band (18 decimals)
     * @param tokenLimit Maximum tokens that can be minted in this band
     */
    function _setRewardBand(
        uint256 bandIndex,
        uint256 minJobValue,
        uint256 maxJobValue,
        uint256 tokensPerDollar,
        uint256 tokenLimit
    ) internal {
        require(minJobValue < maxJobValue, "Min value must be less than max");
        require(tokensPerDollar > 0, "Tokens per dollar must be positive");
        require(tokenLimit > 0, "Token limit must be positive");

        rewardBands[bandIndex] = RewardBand({
            minJobValue: minJobValue,
            maxJobValue: maxJobValue,
            tokensPerDollar: tokensPerDollar,
            tokensMinted: 0,
            tokenLimit: tokenLimit
        });

        if (bandIndex >= currentBandIndex) {
            currentBandIndex = bandIndex + 1;
        }

        emit RewardBandUpdated(bandIndex, minJobValue, maxJobValue, tokensPerDollar);
    }

    /**
     * @dev Update a reward band configuration (admin only)
     * @param bandIndex Index of the band to update
     * @param minJobValue Minimum USD value for jobs in this band (6 decimals)
     * @param maxJobValue Maximum USD value for jobs in this band (6 decimals)
     * @param tokensPerDollar Tokens awarded per dollar in this band (18 decimals)
     * @param tokenLimit Maximum tokens that can be minted in this band
     */
    function updateRewardBand(
        uint256 bandIndex,
        uint256 minJobValue,
        uint256 maxJobValue,
        uint256 tokensPerDollar,
        uint256 tokenLimit
    ) external onlyOwner {
        require(bandIndex < currentBandIndex, "Invalid band index");
        _setRewardBand(bandIndex, minJobValue, maxJobValue, tokensPerDollar, tokenLimit);
    }
}