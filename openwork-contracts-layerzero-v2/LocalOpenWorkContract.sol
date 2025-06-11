// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title IOpenWorkBridge
 * @dev Interface for the OpenWork bridge
 */
interface IOpenWorkBridge {
    function sendMessage(
        uint32 destinationChainSelector,
        address receiver,
        bytes calldata data
    ) external payable returns (bytes32 messageId);
}

/**
 * @title IOpenWorkUserRegistry
 * @dev Interface for the OpenWork User Registry Contract
 */
interface IOpenWorkUserRegistry {
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

    struct Rating {
        uint256 jobId;
        address rater;
        uint8 rating;
        uint256 timestamp;
    }

    struct PortfolioItem {
        uint256 id;
        string title;
        string description;
        string portfolioHash;
        uint256 timestamp;
    }

    function createUserProfile(string memory name, string[] memory skills, string memory profileHash) external;

    function updateUserProfile(string memory name, string memory profileHash) external;

    function getUserProfile(address user) external view returns (
        address userAddress,
        string memory name,
        string[] memory skills,
        string memory profileHash,
        uint256 reputation,
        uint8 averageRating,
        bool exists,
        bool isVerified
    );

    function addSkills(string[] memory skills) external;

    function getSkills(address user) external view returns (string[] memory);

    function incrementReputation(address user, uint8 amount) external;

    function decrementReputation(address user, uint8 amount) external;

    function getReputation(address user) external view returns (uint256);

    function rateUser(uint256 jobId, address rated, uint8 rating) external;

    function addPortfolio(string memory title, string memory description, string memory portfolioHash) external returns (uint256);
}

/**
 * @title IOpenWorkJobMarket
 * @dev Interface for the OpenWork Job Market Contract
 */
interface IOpenWorkJobMarket {
    struct JobPosting {
        uint256 id;
        address client;
        string jobDetailHash; // IPFS hash containing job details
        uint256[] milestonePayments;
        address assignedFreelancer;
        uint8 status; // 0: Open, 1: Assigned, 2: Completed, 3: Cancelled
        uint256 createdAt;
        uint256 updatedAt;
    }

    struct JobApplication {
        address applicant;
        string applicationHash; // IPFS hash containing application details
        uint256[] proposedMilestones;
        string milestoneDetailsHash;
        uint8 status; // 0: Pending, 1: Accepted, 2: Rejected
        uint256 createdAt;
    }

    struct WorkSubmission {
        uint256 id;
        uint256 jobId;
        address freelancer;
        string workHash; // IPFS hash containing work details
        string comments;
        uint8 status; // 0: Submitted, 1: Approved, 2: Rejected
        string feedback;
        uint256 submittedAt;
    }

    function postJob(string memory jobDetailHash, uint256[] memory milestonePayments) external returns (uint256);

    function getJob(uint256 jobId) external view returns (
        uint256 id,
        address client,
        string memory jobDetailHash,
        uint256[] memory milestonePayments,
        address assignedFreelancer,
        uint8 status,
        uint256 createdAt,
        uint256 updatedAt
    );

    function applyToJob(uint256 jobId, string memory applicationHash, uint256[] memory milestonePayments, string memory milestoneDetailsHash) external;

    function proposeMilestones(uint256 jobId, uint256[] memory milestonePayments, string memory milestoneDetailsHash) external;

    function getProposedMilestones(uint256 jobId, address applicant) external view returns (
        uint256[] memory payments,
        string memory detailsHash
    );

    function startJob_LockMilestone1(uint256 jobId, address applicant) external;

    function submitWork(uint256 jobId, string memory workHash, string memory comments) external returns (uint256);

    function approveWork(uint256 submissionId) external;

    function rejectWork(uint256 submissionId, string memory feedback) external;

    function cancelJob(uint256 jobId) external;
}

/**
 * @title LocalOpenWorkContract
 * @dev Contract for managing local chain operations and communicating with the Native OpenWork contract
 */
contract LocalOpenWorkContract is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    // Reference to token used for payments (e.g. USDT)
    IERC20 public paymentToken;

    // Reference to the OpenWork bridge
    address public bridge;

    // Chain ID of the OpenWork chain (LayerZero v2 EID)
    uint32 public openWorkChainId;

    // Addresses of the split OpenWork contracts on the OpenWork chain
    address public userRegistryAddress;
    address public jobMarketAddress;

    // Escrow balances
    mapping(uint256 => uint256) public jobEscrow;

    // Job status
    mapping(uint256 => uint8) public localJobStatus;

    // Payment status for each job milestone
    mapping(uint256 => mapping(uint256 => uint8)) public milestoneFundingStatus; // jobId => milestoneId => status

    // Events
    event JobEscrowFunded(uint256 indexed jobId, uint256 milestoneId, uint256 amount);
    event JobPaymentReleased(uint256 indexed jobId, uint256 milestoneId, address freelancer, uint256 amount);
    event JobPosted(uint256 indexed jobId);
    event JobApplicationSubmitted(uint256 indexed jobId, address applicant);
    event JobInitiated(uint256 indexed jobId, address indexed freelancer);
    event WorkSubmitted(uint256 indexed jobId, uint256 submissionId);
    event MilestoneLocked(uint256 indexed jobId, uint256 milestoneId, uint256 amount);
    event RatingSubmitted(address indexed rater, address indexed rated, uint256 rating);
    event PortfolioAdded(address indexed user, string portfolioHash);
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
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // All configuration parameters start as zero/unset and can be configured post-deployment
        // paymentToken = IERC20(address(0));  // Already default
        // bridge = address(0);                // Already default
        // openWorkChainId = 0;               // Already default
        // userRegistryAddress = address(0);   // Already default
        // jobMarketAddress = address(0);      // Already default

        // Transfer ownership to the specified initial owner
        _transferOwnership(initialOwner);
        emit Initialized(initialOwner);
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Fund a milestone escrow
     * @param jobId The ID of the job
     * @param milestoneId The ID of the milestone
     * @param amount The amount to fund
     */
    function fundMilestoneEscrow(uint256 jobId, uint256 milestoneId, uint256 amount) internal {
        // Check if payment token is set
        require(address(paymentToken) != address(0), "Payment token not set");

        // Transfer tokens from sender to contract
        require(
            paymentToken.transferFrom(msg.sender, address(this), amount),
            "Token transfer failed"
        );

        // Update escrow
        jobEscrow[jobId] += amount;

        // Update milestone funding status
        milestoneFundingStatus[jobId][milestoneId] = 1; // Funded

        // Emit event
        emit JobEscrowFunded(jobId, milestoneId, amount);
    }

    /**
     * @dev Release payment for a milestone to a freelancer
     * @param jobId The ID of the job
     * @param milestoneId The ID of the milestone
     * @param freelancer The address of the freelancer
     */
    function releaseMilestonePayment(uint256 jobId, uint256 milestoneId, address freelancer) internal returns (uint256) {
        // Check if payment token is set
        require(address(paymentToken) != address(0), "Payment token not set");

        // Ensure job exists and is funded
        require(jobEscrow[jobId] > 0, "Job not funded");
        require(milestoneFundingStatus[jobId][milestoneId] == 1, "Milestone not funded");

        // Get the payment amount for this milestone
        uint256 payment = jobEscrow[jobId];

        // Update escrow
        jobEscrow[jobId] = 0;

        // Update milestone funding status
        milestoneFundingStatus[jobId][milestoneId] = 2; // Payment released

        // Transfer payment to freelancer
        require(
            paymentToken.transfer(freelancer, payment),
            "Freelancer payment transfer failed"
        );

        // Emit payment event
        emit JobPaymentReleased(jobId, milestoneId, freelancer, payment);

        return payment;
    }

    /**
     * @dev Get the escrow amount for a job
     * @param jobId The ID of the job
     * @return amount The escrow amount
     */
    function getJobEscrow(uint256 jobId) external view returns (uint256) {
        return jobEscrow[jobId];
    }

    /**
     * @dev Set the payment token address
     * @param _paymentToken The new payment token address
     */
    function setPaymentToken(address _paymentToken) external onlyOwner {
        paymentToken = IERC20(_paymentToken);
    }

    /**
     * @dev Set the bridge address
     * @param _bridge The new bridge address
     */
    function setBridge(address _bridge) external onlyOwner {
        bridge = _bridge;
    }

    /**
     * @dev Set the OpenWork chain ID
     * @param _openWorkChainId The new OpenWork chain ID (LayerZero v2 EID)
     */
    function setOpenWorkChainId(uint32 _openWorkChainId) external onlyOwner {
        openWorkChainId = _openWorkChainId;
    }

    /**
     * @dev Set the User Registry contract address
     * @param _userRegistryAddress The new User Registry contract address
     */
    function setUserRegistryAddress(address _userRegistryAddress) external onlyOwner {
        userRegistryAddress = _userRegistryAddress;
    }

    /**
     * @dev Set the Job Market contract address
     * @param _jobMarketAddress The new Job Market contract address
     */
    function setJobMarketAddress(address _jobMarketAddress) external onlyOwner {
        jobMarketAddress = _jobMarketAddress;
    }

    /**
     * @dev Recover any accidentally sent tokens
     * @param tokenAddress The address of the token
     * @param to The address to send the tokens to
     * @param amount The amount to recover
     */
    function recoverTokens(address tokenAddress, address to, uint256 amount) external onlyOwner {
        IERC20(tokenAddress).transfer(to, amount);
    }

    /**
     * @dev Send a message to the User Registry contract
     * @param data The data to send
     * @return messageId The ID of the message
     */
    function sendMessageToUserRegistry(bytes calldata data) external payable onlyOwner returns (bytes32 messageId) {
        // Send through the bridge
        return IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            userRegistryAddress,
            data
        );
    }

    /**
     * @dev Send a message to the Job Market contract
     * @param data The data to send
     * @return messageId The ID of the message
     */
    function sendMessageToJobMarket(bytes calldata data) external payable onlyOwner returns (bytes32 messageId) {
        // Send through the bridge
        return IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );
    }

    /**
     * @dev Create a user profile - sends a message to the User Registry contract
     * @param name The name of the user
     * @param skills Array of user skills
     * @param profileHash IPFS hash containing extended profile data
     */
    function createUserProfile(
        string memory name,
        string[] memory skills,
        string memory profileHash
    ) external payable nonReentrant {
        // Check if bridge and user registry contract are set
        require(bridge != address(0), "Bridge not set");
        require(userRegistryAddress != address(0), "User Registry address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "createUserProfile(string,string[],string)",
            name,
            skills,
            profileHash
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            userRegistryAddress,
            data
        );
    }

    /**
     * @dev Update a user profile - sends a message to the User Registry contract
     * @param name The updated name of the user
     * @param profileHash Updated IPFS hash containing extended profile data
     */
    function updateUserProfile(
        string memory name,
        string memory profileHash
    ) external payable nonReentrant {
        // Check if bridge and user registry contract are set
        require(bridge != address(0), "Bridge not set");
        require(userRegistryAddress != address(0), "User Registry address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "updateUserProfile(string,string)",
            name,
            profileHash
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            userRegistryAddress,
            data
        );
    }

    /**
     * @dev Add skills to a user profile - sends a message to the User Registry contract
     * Note: This updates the user profile with new skills by calling updateUserProfile
     * @param name The current name of the user (required for update)
     * @param skills Array of skills to add
     * @param profileHash The current profile hash (required for update)
     */
    function addSkills(
        string memory name,
        string[] memory skills,
        string memory profileHash
    ) external payable nonReentrant {
        // Check if bridge and user registry contract are set
        require(bridge != address(0), "Bridge not set");
        require(userRegistryAddress != address(0), "User Registry address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data - use updateUserProfile since addSkills doesn't exist
        bytes memory data = abi.encodeWithSignature(
            "updateUserProfile(string,string[],string)",
            name,
            skills,
            profileHash
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            userRegistryAddress,
            data
        );
    }

    /**
     * @dev Get a user profile - sends a message to the User Registry contract
     * @param user The address of the user
     * @return userAddress The address of the user
     * @return name The name of the user
     * @return skills Array of user skills
     * @return profileHash IPFS hash containing extended profile data
     * @return reputation The user's reputation
     * @return exists Whether the user profile exists
     */
    function getUserProfile(address user) external payable returns (
        address userAddress,
        string memory name,
        string[] memory skills,
        string memory profileHash,
        uint256 reputation,
        bool exists
    ) {
        // Check if bridge and user registry contract are set
        require(bridge != address(0), "Bridge not set");
        require(userRegistryAddress != address(0), "User Registry address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "getUserProfile(address)",
            user
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            userRegistryAddress,
            data
        );

        // Note: This function returns immediately without waiting for the cross-chain call response
        // The actual profile data would need to be fetched through an event or callback mechanism
        return (address(0), "", new string[](0), "", 0, false);
    }

    /**
     * @dev Post a job - sends a message to the Job Market contract
     * @param jobDetailHash IPFS hash containing job details
     * @param milestonePayments Array of milestone payment amounts
     * @return jobId The ID of the created job
     */
    function postJob(
        string memory jobDetailHash,
        uint256[] memory milestonePayments
    ) external payable nonReentrant returns (uint256) {
        // Check if bridge and job market contract are set
        require(bridge != address(0), "Bridge not set");
        require(jobMarketAddress != address(0), "Job Market address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data for posting the job
        bytes memory data = abi.encodeWithSignature(
            "postJob(string,uint256[])",
            jobDetailHash,
            milestonePayments
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );

        // Note: This function returns a placeholder jobId
        // The actual jobId would need to be fetched through an event or callback mechanism
        uint256 tempJobId = uint256(keccak256(abi.encodePacked(msg.sender, block.timestamp, block.number)));
        emit JobPosted(tempJobId);
        return tempJobId;
    }

    /**
     * @dev Apply to a job with optional milestone proposals - sends a message to the Job Market contract
     * @param jobId The ID of the job
     * @param applicationHash IPFS hash containing the job application details
     * @param milestonePayments Optional array of proposed milestone payment amounts (empty array if accepting client's milestones)
     * @param milestoneDetailsHash Optional IPFS hash containing details of each milestone (empty string if accepting client's milestones)
     */
    function applyToJob(
        uint256 jobId, 
        string memory applicationHash, 
        uint256[] memory milestonePayments, 
        string memory milestoneDetailsHash
    ) external payable nonReentrant {
        // Check if bridge and job market contract are set
        require(bridge != address(0), "Bridge not set");
        require(jobMarketAddress != address(0), "Job Market address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data based on whether milestones are proposed
        bytes memory data;

        if (milestonePayments.length > 0) {
            // Applicant is proposing custom milestones
            data = abi.encodeWithSignature(
                "applyToJobWithProposal(uint256,string,uint256[],string)",
                jobId,
                applicationHash,
                milestonePayments,
                milestoneDetailsHash
            );
        } else {
            // Applicant is accepting client's original milestones
            data = abi.encodeWithSignature(
                "applyToJob(uint256,string)",
                jobId,
                applicationHash
            );
        }

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );

        emit JobApplicationSubmitted(jobId, msg.sender);
    }

    /**
     * @dev Propose milestones for a job - sends a message to the Job Market contract
     * @param jobId The ID of the job
     * @param milestonePayments Array of milestone payment amounts
     * @param milestoneDetailsHash IPFS hash containing milestone details
     */
    function proposeMilestones(
        uint256 jobId, 
        uint256[] memory milestonePayments, 
        string memory milestoneDetailsHash
    ) external payable nonReentrant {
        // Check if bridge and job market contract are set
        require(bridge != address(0), "Bridge not set");
        require(jobMarketAddress != address(0), "Job Market address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "proposeMilestones(uint256,uint256[],string)",
            jobId,
            milestonePayments,
            milestoneDetailsHash
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );
    }

    /**
     * @dev Select an applicant and fund the first milestone
     * @param jobId The ID of the job
     * @param applicant The address of the selected applicant
     * @param amount The amount to lock for the first milestone
     */
    function selectApplicantAndFundMilestone(
        uint256 jobId,
        address applicant,
        uint256 amount
    ) external payable nonReentrant {
        // Check if payment token is set
        require(address(paymentToken) != address(0), "Payment token not set");

        // Lock payment for first milestone
        require(
            paymentToken.transferFrom(msg.sender, address(this), amount),
            "Token transfer failed"
        );

        // Update escrow
        jobEscrow[jobId] += amount;

        // Update milestone funding status
        milestoneFundingStatus[jobId][0] = 1; // First milestone (index 0) is now funded

        // Update local job status
        localJobStatus[jobId] = 1; // Funded

        // Emit events
        emit JobEscrowFunded(jobId, 0, amount);
        emit MilestoneLocked(jobId, 0, amount);
        emit JobInitiated(jobId, applicant);

        // Check if bridge and job market contract are set
        require(bridge != address(0), "Bridge not set");
        require(jobMarketAddress != address(0), "Job Market address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data for starting a job with the selected applicant
        bytes memory data = abi.encodeWithSignature(
            "startJob_LockMilestone1(uint256,address)",
            jobId,
            applicant
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );
    }

    /**
     * @dev Submit work for a job - sends a message to the Job Market contract
     * @param jobId The ID of the job
     * @param workHash IPFS hash of the submitted work
     * @param comments Comments about the submission
     * @return submissionId The ID of the work submission
     */
    function submitWork(
        uint256 jobId,
        string memory workHash,
        string memory comments
    ) external payable nonReentrant returns (uint256) {
        // Check if bridge and job market contract are set
        require(bridge != address(0), "Bridge not set");
        require(jobMarketAddress != address(0), "Job Market address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "submitWork(uint256,string,string)",
            jobId,
            workHash,
            comments
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );

        // Note: This function returns a placeholder submissionId
        // The actual submissionId would need to be fetched through an event or callback mechanism
        emit WorkSubmitted(jobId, 0);
        return 0;
    }

    /**
     * @dev Approve work - sends a message to the Job Market contract
     * @param submissionId The ID of the submission
     */
    function approveWork(uint256 submissionId) external payable nonReentrant {
        // Check if bridge and job market contract are set
        require(bridge != address(0), "Bridge not set");
        require(jobMarketAddress != address(0), "Job Market address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "approveWork(uint256)",
            submissionId
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );
    }

    /**
     * @dev Reject work - sends a message to the Job Market contract
     * @param submissionId The ID of the submission
     * @param feedback The feedback for rejection
     */
    function rejectWork(uint256 submissionId, string memory feedback) external payable nonReentrant {
        // Check if bridge and job market contract are set
        require(bridge != address(0), "Bridge not set");
        require(jobMarketAddress != address(0), "Job Market address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "rejectWork(uint256,string)",
            submissionId,
            feedback
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );
    }

    /**
     * @dev Cancel a job - sends a message to the Job Market contract
     * @param jobId The ID of the job
     */
    function cancelJob(uint256 jobId) external payable nonReentrant {
        // Check if bridge and job market contract are set
        require(bridge != address(0), "Bridge not set");
        require(jobMarketAddress != address(0), "Job Market address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "cancelJob(uint256)",
            jobId
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );
    }

    /**
     * @dev Release milestone payment to a freelancer and notify the Job Market contract
     * @param jobId The ID of the job
     * @param milestoneId The ID of the milestone
     * @param freelancer The address of the freelancer
     */
    function releaseMilestonePaymentInterchain(
        uint256 jobId, 
        uint256 milestoneId, 
        address freelancer
    ) external payable nonReentrant {
        // Only the owner can release payment
        require(msg.sender == owner(), "Caller is not the owner");

        // Release the payment using the internal function
        releaseMilestonePayment(jobId, milestoneId, freelancer);

        // Check if bridge and job market address are set
        require(bridge != address(0), "Bridge not set");
        require(jobMarketAddress != address(0), "Job Market address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "completeMilestone_UnlockNext(uint256,uint256)",
            jobId,
            milestoneId
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );
    }

    /**
     * @dev Lock payment for the next milestone - lock payment and notify the Native OpenWork contract
     * @param jobId The ID of the job
     * @param milestoneId The ID of the milestone
     * @param amount The amount to lock for payment
     */
    function lockNextMilestone(uint256 jobId, uint256 milestoneId, uint256 amount) external payable nonReentrant {
        // Lock payment first
        // Transfer tokens from sender to contract
        require(
            paymentToken.transferFrom(msg.sender, address(this), amount),
            "Token transfer failed"
        );

        // Update escrow
        jobEscrow[jobId] += amount;

        // Emit event
        emit MilestoneLocked(jobId, milestoneId, amount);

        // Check if bridge and job market contract are set
        require(bridge != address(0), "Bridge not set");
        require(jobMarketAddress != address(0), "Job Market address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "lockNextMilestoneInterchain(uint256,uint256)",
            jobId,
            amount
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );
    }

    /**
     * @dev Rate a user - sends a message to the User Registry contract
     * @param jobId The ID of the completed job
     * @param user The address of the user to rate
     * @param rating The rating (1-5)
     */
    function rate(uint256 jobId, address user, uint8 rating) external payable nonReentrant {
        require(rating >= 1 && rating <= 5, "Rating must be between 1 and 5");

        // Check if bridge and user registry contract are set
        require(bridge != address(0), "Bridge not set");
        require(userRegistryAddress != address(0), "User Registry address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "rate(uint256,address,uint8)",
            jobId,
            user,
            rating
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            userRegistryAddress,
            data
        );

        emit RatingSubmitted(msg.sender, user, rating);
    }

    /**
     * @dev Get user rating data - sends a message to the User Registry contract
     * @param user The address of the user
     * @return averageRating The user's average rating
     * @return ratingCount The number of ratings for the user
     */
    function getRating(address user) external payable returns (uint8 averageRating, uint256 ratingCount) {
        // Check if bridge and user registry contract are set
        require(bridge != address(0), "Bridge not set");
        require(userRegistryAddress != address(0), "User Registry address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "getRating(address)",
            user
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            userRegistryAddress,
            data
        );

        // Note: This function returns immediately without waiting for the cross-chain call response
        // The actual rating data would need to be fetched through an event or callback mechanism
        return (0, 0);
    }

    /**
     * @dev Add a portfolio item - sends a message to the User Registry contract
     * @param title Title of the portfolio item
     * @param description Description of the portfolio item
     * @param portfolioHash IPFS hash of the portfolio item
     */
    function addPortfolio(
        string memory title,
        string memory description,
        string memory portfolioHash
    ) external payable nonReentrant {
        // Check if bridge and user registry contract are set
        require(bridge != address(0), "Bridge not set");
        require(userRegistryAddress != address(0), "User Registry address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "addPortfolio(string,string,string)",
            title,
            description,
            portfolioHash
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            userRegistryAddress,
            data
        );

        emit PortfolioAdded(msg.sender, portfolioHash);
    }

    /**
     * @dev Fund payment for a specific milestone and notify the Job Market contract
     * @param jobId The ID of the job
     * @param milestoneId The ID of the milestone
     * @param amount The amount to fund for the milestone
     */
    function fundMilestonePaymentInterchain(
        uint256 jobId, 
        uint256 milestoneId, 
        uint256 amount
    ) external payable nonReentrant {
        // Check if payment token is set
        require(address(paymentToken) != address(0), "Payment token not set");

        // Transfer tokens from sender to contract
        require(
            paymentToken.transferFrom(msg.sender, address(this), amount),
            "Token transfer failed"
        );

        // Update escrow
        jobEscrow[jobId] += amount;

        // Update milestone funding status
        milestoneFundingStatus[jobId][milestoneId] = 1; // Funded

        // Emit events
        emit JobEscrowFunded(jobId, milestoneId, amount);
        emit MilestoneLocked(jobId, milestoneId, amount);

        // Check if bridge and job market contract are set
        require(bridge != address(0), "Bridge not set");
        require(jobMarketAddress != address(0), "Job Market address not set");
        require(openWorkChainId != 0, "OpenWork chain ID not set");

        // Encode the function call data
        bytes memory data = abi.encodeWithSignature(
            "milestoneFunded(uint256,uint256)",
            jobId,
            milestoneId
        );

        // Send message through the bridge
        IOpenWorkBridge(bridge).sendMessage{value: msg.value}(
            openWorkChainId,
            jobMarketAddress,
            data
        );
    }
}
