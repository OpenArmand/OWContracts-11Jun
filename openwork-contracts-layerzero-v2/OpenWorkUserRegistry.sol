// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "./interfaces/IOpenWorkUserRegistry.sol";

/**
 * @title OpenWorkUserRegistry
 * @dev Contract for managing user profiles, ratings and portfolios in the OpenWork platform
 */
contract OpenWorkUserRegistry is 
    IOpenWorkUserRegistry,
    Initializable, 
    UUPSUpgradeable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using CountersUpgradeable for CountersUpgradeable.Counter;
    
    // Counters for IDs
    CountersUpgradeable.Counter private _portfolioIdCounter;
    
    // Struct for user profiles
    struct User {
        address userAddress;
        string name;
        string[] skills;
        string profileHash; // IPFS hash for extended profile data
        uint256 reputation;
        uint8 averageRating;
        bool exists;
        bool isVerified;
    }
    
    // Mappings
    mapping(address => User) private _users;
    mapping(address => Rating[]) private _userRatings;
    mapping(address => PortfolioItem[]) private _userPortfolios;
    
    // Permission control
    address private _jobMarketContract;
    
    // Bridge configuration for cross-chain messages
    address public bridge;
    mapping(uint32 => mapping(address => bool)) public trustedSenders;
    
    // Events
    event UserProfileCreated(address indexed user, string name, string profileHash);
    event UserProfileUpdated(address indexed user, string name, string profileHash);
    event UserRated(uint256 indexed jobId, address indexed rated, uint8 rating, address indexed rater);
    event PortfolioItemAdded(address indexed user, uint256 indexed itemId, string title);
    event ReputationIncremented(address indexed user, uint256 amount, uint256 newReputation);
    event JobMarketContractSet(address indexed jobMarketContract);
    event BridgeSet(address indexed bridge);
    event TrustedSenderSet(uint32 indexed chainId, address indexed sender, bool trusted);
    event CrossChainMessageReceived(uint32 indexed srcChainId, address indexed sender, string functionName);
    
    /**
     * @dev Modifier to restrict access to only the job market contract or the owner
     */
    modifier onlyJobMarketOrOwner() {
        require(
            msg.sender == _jobMarketContract || msg.sender == owner(),
            "Not authorized: must be job market contract or owner"
        );
        _;
    }
    
    /**
     * @dev Initialize the contract
     */
    /**
     * @dev Initialize the contract with a specific owner
     * @param initialOwner Address of the initial owner
     */
    function initialize(address initialOwner) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        // Transfer ownership to the specified address if it's not zero
        if (initialOwner != address(0)) {
            _transferOwnership(initialOwner);
        }
    }
    
    /**
     * @dev Set the job market contract address
     * @param jobMarketAddress The address of the job market contract
     */
    function setJobMarketContract(address jobMarketAddress) external onlyOwner {
        _jobMarketContract = jobMarketAddress;
        emit JobMarketContractSet(jobMarketAddress);
    }
    
    /**
     * @dev Set the bridge contract address
     * @param _bridge The address of the bridge contract
     */
    function setBridge(address _bridge) external onlyOwner {
        bridge = _bridge;
        emit BridgeSet(_bridge);
    }
    
    /**
     * @dev Set trusted sender for cross-chain messages
     * @param chainId The chain ID of the sender
     * @param sender The address of the trusted sender
     * @param trusted Whether the sender is trusted
     */
    function setTrustedSender(uint32 chainId, address sender, bool trusted) external onlyOwner {
        trustedSenders[chainId][sender] = trusted;
        emit TrustedSenderSet(chainId, sender, trusted);
    }
    
    /**
     * @dev Check if a user exists
     * @param userAddress The address of the user
     * @return exists True if the user exists
     */
    function userExists(address userAddress) public view returns (bool) {
        return _users[userAddress].exists;
    }
    
    /**
     * @dev Create a new user profile
     * @param name The name of the user
     * @param skills Array of user skills
     * @param profileHash IPFS hash containing extended profile data
     */
    function createUserProfile(
        string memory name, 
        string[] memory skills, 
        string memory profileHash
    ) public {
        require(!userExists(msg.sender), "User profile already exists");
        require(bytes(profileHash).length > 0, "Profile hash cannot be empty");
        
        _users[msg.sender] = User({
            userAddress: msg.sender,
            name: name,
            skills: skills,
            profileHash: profileHash,
            reputation: 0,
            averageRating: 0,
            exists: true,
            isVerified: false
        });
        
        emit UserProfileCreated(msg.sender, name, profileHash);
    }
    
    /**
     * @dev Create a new user profile - Interface method that forwards to implementation
     * @param name The name of the user
     * @param skills Array of user skills
     * @param profileHash IPFS hash containing extended profile data
     */
    function createProfile(
        string memory name, 
        string[] memory skills, 
        string memory profileHash
    ) external {
        createUserProfile(name, skills, profileHash);
    }
    
    /**
     * @dev Update an existing user profile
     * @param name The updated name of the user
     * @param skills Updated array of user skills
     * @param profileHash IPFS hash containing extended profile data
     */
    function updateUserProfile(
        string memory name, 
        string[] memory skills, 
        string memory profileHash
    ) public {
        require(userExists(msg.sender), "User profile does not exist");
        require(bytes(profileHash).length > 0, "Profile hash cannot be empty");
        
        User storage user = _users[msg.sender];
        user.name = name;
        user.skills = skills;
        user.profileHash = profileHash;
        
        emit UserProfileUpdated(msg.sender, name, profileHash);
    }
    
    /**
     * @dev Update an existing user profile - Interface method that forwards to implementation
     * @param name The updated name of the user
     * @param skills Updated array of user skills
     * @param profileHash IPFS hash containing extended profile data
     */
    function updateProfile(
        string memory name, 
        string[] memory skills, 
        string memory profileHash
    ) external {
        updateUserProfile(name, skills, profileHash);
    }
    
    /**
     * @dev Get user profile details
     * @param user The address of the user
     */
    function getUserProfile(address user) 
        external 
        view
        returns (
            address userAddress,
            string memory name,
            string[] memory skills,
            string memory profileHash,
            uint256 reputation,
            bool exists
        ) 
    {
        User storage userProfile = _users[user];
        
        return (
            userProfile.userAddress,
            userProfile.name,
            userProfile.skills,
            userProfile.profileHash,
            userProfile.reputation,
            userProfile.exists
        );
    }
    
    /**
     * @dev Get user profile details - Interface method with different return values
     * @param userAddress The address of the user
     */
    function getProfile(address userAddress) external view returns (
        string memory name,
        string[] memory skills,
        string memory profileHash,
        bool isVerified,
        bool exists
    ) {
        User storage user = _users[userAddress];
        return (
            user.name,
            user.skills,
            user.profileHash,
            user.isVerified,
            user.exists
        );
    }
    
    /**
     * @dev Rate a user (job giver or freelancer) after job completion
     * @param jobId The ID of the completed job
     * @param user The address of the user to rate
     * @param rating The rating (1-5)
     */
    function rate(uint256 jobId, address user, uint8 rating) external onlyJobMarketOrOwner {
        require(userExists(user), "User profile does not exist");
        require(rating >= 1 && rating <= 5, "Rating must be between 1 and 5");
        
        // Store the rating for the user
        _userRatings[user].push(Rating({
            jobId: jobId,
            rater: msg.sender,
            rating: rating,
            timestamp: block.timestamp
        }));
        
        // Update the average rating
        User storage userProfile = _users[user];
        uint256 totalRatings = _userRatings[user].length;
        uint256 totalRatingValue = 0;
        
        for (uint256 i = 0; i < totalRatings; i++) {
            totalRatingValue += _userRatings[user][i].rating;
        }
        
        userProfile.averageRating = uint8(totalRatingValue / totalRatings);
        
        emit UserRated(jobId, user, rating, msg.sender);
    }
    
    /**
     * @dev Get the rating data for a user
     * @param user The address of the user
     * @return averageRating The average rating of the user
     * @return ratingCount The number of ratings for the user
     */
    function getRating(address user) external view returns (uint8 averageRating, uint256 ratingCount) {
        return (_users[user].averageRating, _userRatings[user].length);
    }
    
    /**
     * @dev Get a specific rating for a user
     * @param user The address of the user
     * @param index The index of the rating
     * @return jobId The ID of the job
     * @return rater The address of the rater
     * @return rating The rating value
     * @return timestamp The time the rating was given
     */
    function getRatingDetails(address user, uint256 index) external view returns (
        uint256 jobId,
        address rater,
        uint8 rating,
        uint256 timestamp
    ) {
        require(index < _userRatings[user].length, "Rating index out of bounds");
        
        Rating storage ratingData = _userRatings[user][index];
        return (
            ratingData.jobId,
            ratingData.rater,
            ratingData.rating,
            ratingData.timestamp
        );
    }
    
    /**
     * @dev Add a portfolio item to a user's profile
     * @param title The title of the portfolio item
     * @param description The description of the portfolio item
     * @param contentHash IPFS hash pointing to portfolio content
     * @return itemId The ID of the created portfolio item
     */
    function addPortfolio(
        string memory title,
        string memory description,
        string memory contentHash
    ) external returns (uint256) {
        require(userExists(msg.sender), "User profile does not exist");
        require(bytes(title).length > 0, "Title cannot be empty");
        require(bytes(contentHash).length > 0, "Content hash cannot be empty");
        
        uint256 itemId = _portfolioIdCounter.current();
        _portfolioIdCounter.increment();
        
        _userPortfolios[msg.sender].push(PortfolioItem({
            id: itemId,
            title: title,
            description: description,
            contentHash: contentHash,
            createdAt: block.timestamp
        }));
        
        emit PortfolioItemAdded(msg.sender, itemId, title);
        
        return itemId;
    }
    
    /**
     * @dev Get the number of portfolio items for a user
     * @param user The address of the user
     * @return count The number of portfolio items
     */
    function getPortfolioCount(address user) external view returns (uint256) {
        return _userPortfolios[user].length;
    }
    
    /**
     * @dev Get portfolio item details
     * @param user The address of the user
     * @param itemId The ID of the portfolio item
     * @return title The title of the portfolio item
     * @return description The description of the portfolio item
     * @return contentHash IPFS hash pointing to portfolio content
     * @return createdAt The creation timestamp of the portfolio item
     */
    function getPortfolioItem(
        address user,
        uint256 itemId
    ) external view returns (
        string memory title,
        string memory description,
        string memory contentHash,
        uint256 createdAt
    ) {
        require(itemId < _userPortfolios[user].length, "Portfolio item index out of bounds");
        
        PortfolioItem storage item = _userPortfolios[user][itemId];
        return (
            item.title,
            item.description,
            item.contentHash,
            item.createdAt
        );
    }
    
    /**
     * @dev Increment the reputation of a user
     * @param user The address of the user
     * @param amount The amount to increment
     * @return newReputation The new reputation value
     */
    function incrementReputation(address user, uint256 amount) external onlyJobMarketOrOwner returns (uint256) {
        require(userExists(user), "User profile does not exist");
        
        User storage userProfile = _users[user];
        userProfile.reputation += amount;
        
        emit ReputationIncremented(user, amount, userProfile.reputation);
        
        return userProfile.reputation;
    }
    
    /**
     * @dev Receive cross-chain messages from the bridge
     * @param srcChainId The source chain ID
     * @param sender The original sender address
     * @param message The encoded message data
     */
    function receiveMessage(
        uint32 srcChainId,
        address sender,
        bytes calldata message
    ) external {
        // Ensure the caller is the bridge
        require(msg.sender == bridge, "Only bridge can call");
        
        // Ensure the sender is trusted
        require(trustedSenders[srcChainId][sender], "Untrusted sender");
        
        // Decode the function selector (first 4 bytes)
        bytes4 functionSelector;
        assembly {
            functionSelector := calldataload(add(message.offset, 0))
        }
        
        // Route to appropriate function based on selector
        if (functionSelector == bytes4(keccak256("createUserProfile(string,string[],string)"))) {
            _handleCreateUserProfile(sender, message);
        } else if (functionSelector == bytes4(keccak256("updateUserProfile(string,string)"))) {
            _handleUpdateUserProfile(sender, message);
        } else if (functionSelector == bytes4(keccak256("updateUserProfile(string,string[],string)"))) {
            _handleUpdateUserProfileWithSkills(sender, message);
        } else {
            revert("Unsupported function");
        }
    }
    
    /**
     * @dev Handle cross-chain createUserProfile calls
     * @param originalSender The original sender from the source chain
     * @param message The encoded message data
     */
    function _handleCreateUserProfile(address originalSender, bytes calldata message) internal {
        // Decode the parameters - message already has function selector stripped by bridge
        (string memory name, string[] memory skills, string memory profileHash) = abi.decode(
            message[4:], // Skip the function selector from the original encoded call
            (string, string[], string)
        );
        
        // Create profile for the original sender (not the bridge)
        require(!userExists(originalSender), "User profile already exists");
        require(bytes(profileHash).length > 0, "Profile hash cannot be empty");
        
        _users[originalSender] = User({
            userAddress: originalSender,
            name: name,
            skills: skills,
            profileHash: profileHash,
            reputation: 0,
            averageRating: 0,
            exists: true,
            isVerified: false
        });
        
        emit UserProfileCreated(originalSender, name, profileHash);
        emit CrossChainMessageReceived(0, originalSender, "createUserProfile");
    }
    
    /**
     * @dev Handle cross-chain updateUserProfile calls
     * @param originalSender The original sender from the source chain
     * @param message The encoded message data
     */
    function _handleUpdateUserProfile(address originalSender, bytes calldata message) internal {
        // For updateUserProfile, LocalOpenWorkContract only sends name and profileHash
        // We need to get existing skills and update with new name/profileHash
        (string memory name, string memory profileHash) = abi.decode(
            message[4:], // Skip the function selector
            (string, string)
        );
        
        // Update profile for the original sender
        require(userExists(originalSender), "User profile does not exist");
        require(bytes(profileHash).length > 0, "Profile hash cannot be empty");
        
        User storage user = _users[originalSender];
        user.name = name;
        user.profileHash = profileHash;
        // Keep existing skills unchanged
        
        emit UserProfileUpdated(originalSender, name, profileHash);
        emit CrossChainMessageReceived(0, originalSender, "updateUserProfile");
    }
    
    /**
     * @dev Handle cross-chain updateUserProfile calls with skills (from addSkills function)
     * @param originalSender The original sender from the source chain
     * @param message The encoded message data
     */
    function _handleUpdateUserProfileWithSkills(address originalSender, bytes calldata message) internal {
        // For addSkills, LocalOpenWorkContract sends name, skills, and profileHash
        (string memory name, string[] memory skills, string memory profileHash) = abi.decode(
            message[4:], // Skip the function selector
            (string, string[], string)
        );
        
        // Update profile for the original sender with new skills
        require(userExists(originalSender), "User profile does not exist");
        require(bytes(profileHash).length > 0, "Profile hash cannot be empty");
        
        User storage user = _users[originalSender];
        user.name = name;
        user.skills = skills; // Update skills array
        user.profileHash = profileHash;
        
        emit UserProfileUpdated(originalSender, name, profileHash);
        emit CrossChainMessageReceived(0, originalSender, "addSkills");
    }

    /**
     * @dev Required by UUPSUpgradeable - Only owner can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}