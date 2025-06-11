// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "./interfaces/IOpenWorkJobMarket.sol";
import "./interfaces/IOpenWorkUserRegistry.sol";
import "./interfaces/IUnifiedRewardsTracking.sol";

/**
 * @title OpenWorkJobMarket
 * @dev Contract for managing the job marketplace in the OpenWork platform
 */
contract OpenWorkJobMarket is 
    IOpenWorkJobMarket,
    Initializable, 
    UUPSUpgradeable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    // Maximum job value in USDT (10,000 USDT)
    uint256 private constant MAX_JOB_VALUE = 10000 * 10**18;
    using CountersUpgradeable for CountersUpgradeable.Counter;

    // Counters for IDs
    CountersUpgradeable.Counter private _jobIdCounter;
    CountersUpgradeable.Counter private _submissionIdCounter;

    // Struct for tracking job data
    struct Job {
        uint256 id;
        address jobGiver;
        address[] applicants;
        string jobDetailHash;
        bool isOpen;
        bool isCompleted;
        string[] workSubmissions;
        uint256[] milestonePayments;
        uint256 totalPaid;
        uint256 currentLockedAmount;
        uint256 currentMilestone;
        address selectedApplicant;
        uint256 createdAt;
        mapping(address => string) proposals;
        mapping(address => ProposedMilestones) proposedMilestones;
    }

    // Struct for work submissions
    struct Submission {
        uint256 id;
        uint256 jobId;
        address freelancer;
        string workHash;
        string comments;
        uint8 status; // 0: Submitted, 1: Approved, 2: Rejected
        uint256 submittedAt;
        string feedback;
    }

    // Struct for milestones
    struct Milestone {
        uint256 id;
        uint256 jobId;
        string description;
        uint256 amount;
        bool completed;
        bool paid;
        uint256 dueDate;
    }

    // Contract references
    IUnifiedRewardsTracking private _earningsContract;
    IOpenWorkUserRegistry private _userRegistry;

    // Mappings
    mapping(uint256 => Job) private _jobs;
    mapping(uint256 => Submission) private _submissions;
    mapping(uint256 => Milestone[]) private _milestones;
    mapping(uint256 => uint256) private _disputeLockedFunds;

    // Events
    event JobCreated(uint256 indexed jobId, address indexed jobGiver, string jobDetailHash, uint256 budget);
    event JobApplicationSubmitted(uint256 indexed jobId, address indexed freelancer);
    event JobAssigned(uint256 indexed jobId, address indexed freelancer);
    event WorkSubmitted(uint256 indexed submissionId, uint256 indexed jobId, address indexed freelancer);
    event WorkApproved(uint256 indexed submissionId, uint256 indexed jobId);
    event WorkRejected(uint256 indexed submissionId, uint256 indexed jobId, string feedback);
    event JobCancelled(uint256 indexed jobId);
    event FundsLocked(uint256 indexed jobId, uint256 indexed disputeId, uint256 amount);
    event DisputedFundsReleased(uint256 indexed jobId, uint256 indexed disputeId, uint256 amount);
    event MilestoneCreated(uint256 indexed jobId, uint256 indexed milestoneId, string description, uint256 amount);
    event MilestoneCompleted(uint256 indexed jobId, uint256 indexed milestoneId, uint256 amount);
    event MilestonePaid(uint256 indexed jobId, uint256 indexed milestoneId, uint256 amount);
    event JobFunded(uint256 indexed jobId, uint256 amount);
    event JobCompleted(uint256 indexed jobId);
    event MilestoneLocked(uint256 indexed jobId, uint256 indexed milestoneIndex, uint256 amount);
    event NextMilestoneReady(uint256 indexed jobId, uint256 milestoneIndex, uint256 amount);
    event DisputeCreated(uint256 indexed jobId, string reason, address indexed initiator);
    event JobMilestonesUpdated(uint256 indexed jobId, address indexed applicant);
    event EarningsRecorded(address indexed user, uint256 amount);
    event UserRegistryContractSet(address indexed userRegistryContract);
    event EarningsContractSet(address indexed earningsContract);

    /**
     * @dev Initialize the contract
     */
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    /**
     * @dev Initialize the contract with external contracts
     * @param userRegistryAddress The address of the user registry contract
     * @param earningsContractAddress The address of the earnings contract
     */
    function initializeWithContracts(
        address userRegistryAddress,
        address earningsContractAddress
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (userRegistryAddress != address(0)) {
            _userRegistry = IOpenWorkUserRegistry(userRegistryAddress);
            emit UserRegistryContractSet(userRegistryAddress);
        }

        if (earningsContractAddress != address(0)) {
            _earningsContract = IUnifiedRewardsTracking(earningsContractAddress);
            emit EarningsContractSet(earningsContractAddress);
        }
    }

    /**
     * @dev Set the user registry contract address
     * @param userRegistryAddress The address of the user registry contract
     */
    function setUserRegistryContract(address userRegistryAddress) external onlyOwner {
        _userRegistry = IOpenWorkUserRegistry(userRegistryAddress);
        emit UserRegistryContractSet(userRegistryAddress);
    }

    /**
     * @dev Set the earnings rewards contract address
     * @param earningsContractAddress Address of the earnings contract
     */
    function setEarningsContract(address earningsContractAddress) external onlyOwner {
        _earningsContract = IUnifiedRewardsTracking(earningsContractAddress);
        emit EarningsContractSet(earningsContractAddress);
    }

    /**
     * @dev Check if the user registry is configured
     * @return bool True if the user registry is set
     */
    function isUserRegistryConfigured() public view returns (bool) {
        return address(_userRegistry) != address(0);
    }

    /**
     * @dev Check if a user exists
     * @param user The address of the user
     * @return bool True if the user exists
     */
    function _userExists(address user) internal view returns (bool) {
        if (isUserRegistryConfigured()) {
            return _userRegistry.userExists(user);
        } else {
            // Legacy behavior for backward compatibility
            return true;
        }
    }

    /**
     * @dev Check if a job exists
     * @param jobId The ID of the job
     * @return bool True if the job exists
     */
    function _jobExists(uint256 jobId) internal view returns (bool) {
        return _jobs[jobId].jobGiver != address(0);
    }

    /**
     * @dev Check if a job exists - External interface
     * @param jobId ID of the job
     * @return exists True if the job exists
     */
    function jobExists(uint256 jobId) external view returns (bool exists) {
        return _jobExists(jobId);
    }

    /**
     * @dev Helper function to set job detail hash
     * @param jobId ID of the job
     * @param jobDetailHash IPFS hash containing job details
     */
    function _setJobDetailHash(uint256 jobId, string memory jobDetailHash) internal {
        require(bytes(jobDetailHash).length > 0, "Job detail hash cannot be empty");
        _jobs[jobId].jobDetailHash = jobDetailHash;
    }

    /**
     * @dev Helper function to set milestone payments
     * @param jobId ID of the job
     * @param milestonePayments Array of milestone payment amounts
     */
    function _setMilestonePayments(uint256 jobId, uint256[] memory milestonePayments) internal {
        require(milestonePayments.length > 0, "Must have at least one milestone payment");
        uint256 totalPayment = 0;
        for (uint256 i = 0; i < milestonePayments.length; i++) {
            require(milestonePayments[i] > 0, "Milestone payment must be greater than 0");
            totalPayment += milestonePayments[i];
        }
        require(totalPayment > 0, "Total payment must be greater than 0");
        require(totalPayment <= MAX_JOB_VALUE, "Job value exceeds maximum limit of 10K USDT");

        _jobs[jobId].milestonePayments = milestonePayments;
    }

    /**
     * @dev Helper function to set job as open
     * @param jobId ID of the job
     */
    function _setIsOpen(uint256 jobId) internal {
        _jobs[jobId].isOpen = true;
    }

    /**
     * @dev Create a new job posting
     * @param ipfsHash IPFS hash containing job details
     * @param milestones Array of milestone payment amounts
     * @return jobId The ID of the created job
     */
    function postJob(
        string memory ipfsHash,
        uint256[] memory milestones
    ) external returns (uint256) {
        require(_userExists(msg.sender), "User profile does not exist");
        require(bytes(ipfsHash).length > 0, "IPFS hash cannot be empty");
        require(milestones.length > 0, "Must have at least one milestone");

        uint256 jobId = _jobIdCounter.current();
        _jobIdCounter.increment();

        Job storage job = _jobs[jobId];
        job.id = jobId;
        job.jobGiver = msg.sender;
        job.createdAt = block.timestamp;
        job.currentMilestone = 0;
        job.totalPaid = 0;
        job.currentLockedAmount = 0;
        job.isCompleted = false;

        // Set job details using helper functions
        _setJobDetailHash(jobId, ipfsHash);
        _setMilestonePayments(jobId, milestones);
        _setIsOpen(jobId);

        // Calculate total budget for event
        uint256 totalBudget = 0;
        for (uint256 i = 0; i < milestones.length; i++) {
            totalBudget += milestones[i];
        }

        emit JobCreated(jobId, msg.sender, ipfsHash, totalBudget);

        return jobId;
    }

    /**
     * @dev Apply for a job with optional proposed milestones
     * @param jobId The ID of the job
     * @param application_hash IPFS hash containing the application details
     * @param proposedMilestones Array of proposed milestone payment amounts (optional)
     * @param milestoneDetailsHash IPFS hash containing milestone descriptions (optional)
     */
    function applyToJobWithProposal(
        uint256 jobId, 
        string memory application_hash, 
        uint256[] memory proposedMilestones,
        string memory milestoneDetailsHash
    ) public {
        require(_userExists(msg.sender), "User profile does not exist");
        require(_jobExists(jobId), "Job does not exist");
        require(_jobs[jobId].isOpen, "Job is not open for applications");
        require(_jobs[jobId].jobGiver != msg.sender, "Cannot apply to your own job");

        // Get job details
        Job storage job = _jobs[jobId];

        // Check if already applied
        for (uint256 i = 0; i < job.applicants.length; i++) {
            if (job.applicants[i] == msg.sender) {
                revert("Already applied to this job");
            }
        }

        // Add application
        job.applicants.push(msg.sender);
        job.proposals[msg.sender] = application_hash;

        // Store milestone proposal if provided
        if (proposedMilestones.length > 0) {
            // Validate proposed milestones
            uint256 totalPayment = 0;
            for (uint256 i = 0; i < proposedMilestones.length; i++) {
                require(proposedMilestones[i] > 0, "Proposed milestone payment must be greater than 0");
                totalPayment += proposedMilestones[i];
            }
            require(totalPayment > 0, "Total proposed payment must be greater than 0");
            require(totalPayment <= MAX_JOB_VALUE, "Proposed job value exceeds maximum limit of 10K USDT");

            job.proposedMilestones[msg.sender] = ProposedMilestones({
                hasMilestoneProposal: true,
                milestonePayments: proposedMilestones,
                milestoneDetailsHash: milestoneDetailsHash
            });
        }

        emit JobApplicationSubmitted(jobId, msg.sender);
    }

    /**
     * @dev Apply for a job - original function
     * @param jobId The ID of the job
     * @param application_hash IPFS hash containing the application details
     */
    function applyToJob(uint256 jobId, string memory application_hash) public {
        applyToJobWithProposal(jobId, application_hash, new uint256[](0), "");
    }

    /**
     * @dev Apply for a job (legacy function)
     * @param jobId The ID of the job
     * @param proposal The proposal text
     */
    function applyForJob(uint256 jobId, string memory proposal) external {
        applyToJob(jobId, proposal);
    }

    /**
     * @dev Helper function to check if user is the job giver
     * @param jobId ID of the job
     * @param user Address of the user
     */
    function _isJobGiver(uint256 jobId, address user) internal view returns (bool) {
        return _jobs[jobId].jobGiver == user;
    }

    /**
     * @dev Helper function to lock a payment amount for a specific milestone
     * @param jobId ID of the job
     * @param milestoneIndex Index of the milestone
     * @param amount Amount to lock
     */
    function _lockMilestonePayment(uint256 jobId, uint256 milestoneIndex, uint256 amount) internal {
        require(milestoneIndex < _jobs[jobId].milestonePayments.length, "Invalid milestone index");
        _jobs[jobId].currentLockedAmount = amount;

        emit MilestoneLocked(jobId, milestoneIndex, amount);
    }

    /**
     * @dev Helper function to add selected applicant
     * @param jobId ID of the job
     * @param applicant Address of the selected applicant
     */
    function _addSelectedApplicant(uint256 jobId, address applicant) internal {
        _jobs[jobId].selectedApplicant = applicant;
        _jobs[jobId].isOpen = false;

        emit JobAssigned(jobId, applicant);
    }

    /**
     * @dev Helper function to implement job start with milestone proposal acceptance
     * @param jobId ID of the job
     * @param applicant Address of the selected applicant
     * @param acceptProposedMilestones Whether to accept the applicant's proposed milestones
     */
    function _implementJobStart(
        uint256 jobId, 
        address applicant, 
        bool acceptProposedMilestones
    ) internal {
        Job storage job = _jobs[jobId];

        // Check if the applicant has applied for the job
        bool hasApplied = false;
        for (uint256 i = 0; i < job.applicants.length; i++) {
            if (job.applicants[i] == applicant) {
                hasApplied = true;
                break;
            }
        }
        require(hasApplied, "Applicant has not applied for this job");

        // Accept proposed milestones if requested and available
        if (acceptProposedMilestones && job.proposedMilestones[applicant].hasMilestoneProposal) {
            _setMilestonePayments(jobId, job.proposedMilestones[applicant].milestonePayments);
            emit JobMilestonesUpdated(jobId, applicant);
        }

        // Add selected applicant
        _addSelectedApplicant(jobId, applicant);
    }

    /**
     * @dev Function to start a job with a basic workflow
     * @param jobId ID of the job 
     * @param applicant Address of the applicant
     */
    function _startJobBasic(uint256 jobId, address applicant) internal {
        require(_jobExists(jobId), "Job does not exist");
        require(_isJobGiver(jobId, msg.sender), "Only job giver can assign the job");

        _implementJobStart(jobId, applicant, false);

        // Lock the first milestone payment
        Job storage job = _jobs[jobId];
        uint256 milestonePayment = job.milestonePayments[0];
        require(msg.value >= milestonePayment, "Insufficient funds to lock first milestone payment");

        _lockMilestonePayment(jobId, 0, milestonePayment);

        // Refund excess value if sent
        if (msg.value > milestonePayment) {
            payable(msg.sender).transfer(msg.value - milestonePayment);
        }
    }

    /**
     * @dev Start a job and accept milestone proposal
     * @param jobId The ID of the job
     * @param applicant The address of the selected applicant
     * @param acceptProposedMilestones Whether to accept the applicant's proposed milestones
     */
    function startJobWithProposedMilestones(uint256 jobId, address applicant, bool acceptProposedMilestones) external payable {
        require(_jobExists(jobId), "Job does not exist");
        require(_isJobGiver(jobId, msg.sender), "Only job giver can assign the job");

        _implementJobStart(jobId, applicant, acceptProposedMilestones);

        // Lock the first milestone payment
        Job storage job = _jobs[jobId];
        uint256 milestonePayment = job.milestonePayments[0];
        require(msg.value >= milestonePayment, "Insufficient funds to lock first milestone payment");

        _lockMilestonePayment(jobId, 0, milestonePayment);

        // Refund excess value if sent
        if (msg.value > milestonePayment) {
            payable(msg.sender).transfer(msg.value - milestonePayment);
        }
    }

    /**
     * @dev Start job and lock the first milestone payment (original function)
     * @param jobId The ID of the job
     * @param applicant The address of the selected applicant
     */
    function startJob_LockMilestone1(uint256 jobId, address applicant) external payable {
        _startJobBasic(jobId, applicant);
    }

    /**
     * @dev Legacy function for assigning a job to a freelancer - kept for backward compatibility
     * @param jobId The ID of the job
     * @param freelancer The address of the selected freelancer
     */
    function assignJob(uint256 jobId, address freelancer) public payable {
        _startJobBasic(jobId, freelancer);
    }

    /**
     * @dev Legacy function for assigning a job to a freelancer - kept for backward compatibility
     * @param jobId The ID of the job
     * @param freelancer The address of the selected freelancer
     */
    function selectApplicant(uint256 jobId, address freelancer) external payable {
        assignJob(jobId, freelancer);
    }

    /**
     * @dev Start a job for an interchain application
     * @param jobId The ID of the job
     * @param applicant The address of the selected applicant
     * @param acceptProposedMilestones Whether to accept the applicant's proposed milestones
     */
    function startJobInterChain(uint256 jobId, address applicant, bool acceptProposedMilestones) external {
        require(_jobExists(jobId), "Job does not exist");
        require(_isJobGiver(jobId, msg.sender), "Only job giver can assign the job");

        _implementJobStart(jobId, applicant, acceptProposedMilestones);

        // For interchain jobs, we don't lock any payment here
        // The payment is locked on the local chain
    }

    /**
     * @dev Submit work for a job
     * @param jobId ID of the job
     * @param workHash IPFS hash containing the submitted work
     * @param comments Additional comments for the submission
     * @return submissionId The ID of the created submission
     */
    function submitWork(
        uint256 jobId,
        string memory workHash,
        string memory comments
    ) external returns (uint256) {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(!job.isOpen, "Job must be assigned before submitting work");
        require(!job.isCompleted, "Job is already completed");
        require(job.selectedApplicant == msg.sender, "Only the assigned freelancer can submit work");
        require(bytes(workHash).length > 0, "Work hash cannot be empty");

        uint256 submissionId = _submissionIdCounter.current();
        _submissionIdCounter.increment();

        Submission storage submission = _submissions[submissionId];
        submission.id = submissionId;
        submission.jobId = jobId;
        submission.freelancer = msg.sender;
        submission.workHash = workHash;
        submission.comments = comments;
        submission.status = 0; // Submitted
        submission.submittedAt = block.timestamp;

        job.workSubmissions.push(workHash);

        emit WorkSubmitted(submissionId, jobId, msg.sender);

        return submissionId;
    }

    /**
     * @dev Approve submitted work
     * @param submissionId ID of the submission
     */
    function approveWork(uint256 submissionId) external {
        Submission storage submission = _submissions[submissionId];
        require(submission.id == submissionId, "Submission does not exist");
        require(submission.status == 0, "Submission must be in submitted status");

        Job storage job = _jobs[submission.jobId];
        require(_isJobGiver(submission.jobId, msg.sender), "Only job giver can approve work");

        submission.status = 1; // Approved

        // Release payment for current milestone
        uint256 currentMilestone = job.currentMilestone;
        uint256 amountToRelease = job.currentLockedAmount;
        address freelancer = submission.freelancer;

        job.currentLockedAmount = 0;
        job.totalPaid += amountToRelease;

        // Transfer funds to the freelancer
        if (amountToRelease > 0) {
            payable(freelancer).transfer(amountToRelease);

            // Record earnings if earnings contract is set
            if (address(_earningsContract) != address(0)) {
                _earningsContract.recordEarnings(freelancer, amountToRelease);
                emit EarningsRecorded(freelancer, amountToRelease);
            }
        }

        // Increment reputation if user registry is configured
        if (isUserRegistryConfigured()) {
            _userRegistry.incrementReputation(freelancer, 1);
        }

        // Check if this was the last milestone
        if (currentMilestone == job.milestonePayments.length - 1) {
            job.isCompleted = true;
            emit JobCompleted(submission.jobId);
        } else {
            // Prepare for next milestone
            job.currentMilestone++;
            emit NextMilestoneReady(submission.jobId, currentMilestone + 1, job.milestonePayments[currentMilestone + 1]);
        }

        emit WorkApproved(submissionId, submission.jobId);
    }

    /**
     * @dev Reject submitted work
     * @param submissionId ID of the submission
     * @param feedback Feedback explaining the rejection
     */
    function rejectWork(uint256 submissionId, string memory feedback) external {
        Submission storage submission = _submissions[submissionId];
        require(submission.id == submissionId, "Submission does not exist");
        require(submission.status == 0, "Submission must be in submitted status");

        require(_isJobGiver(submission.jobId, msg.sender), "Only job giver can reject work");

        submission.status = 2; // Rejected
        submission.feedback = feedback;

        emit WorkRejected(submissionId, submission.jobId, feedback);
    }

    /**
     * @dev Cancel a job
     * @param jobId ID of the job
     * @return success True if the job was cancelled
     */
    function cancelJob(uint256 jobId) external returns (bool) {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(_isJobGiver(jobId, msg.sender), "Only job giver can cancel the job");
        require(!job.isCompleted, "Job is already completed");

        uint256 refundAmount = job.currentLockedAmount;
        job.currentLockedAmount = 0;
        job.isOpen = false;
        job.isCompleted = true;

        if (refundAmount > 0) {
            payable(msg.sender).transfer(refundAmount);
        }

        emit JobCancelled(jobId);

        return true;
    }

    /**
     * @dev Get job posting details
     * @param jobId ID of the job
     * @return id Job ID
     * @return client Client address
     * @return title Job title (empty for new format)
     * @return description Job description (empty for new format)
     * @return budget Total budget
     * @return deadline Job deadline (0 for new format)
     * @return createdAt Creation timestamp
     * @return freelancer Selected freelancer address
     * @return status Job status (0: open, 1: in progress, 2: completed, 3: cancelled)
     * @return completedAt Completion timestamp (0 if not completed)
     */
    function getJobPosting(uint256 jobId) 
        external 
        view
        returns (
            uint256 id,
            address client,
            string memory title,
            string memory description,
            uint256 budget,
            uint256 deadline,
            uint256 createdAt,
            address freelancer,
            uint256 status,
            uint256 completedAt
        ) 
    {
        require(_jobExists(jobId), "Job does not exist");

        Job storage job = _jobs[jobId];

        // Calculate total budget
        uint256 totalBudget = 0;
        for (uint256 i = 0; i < job.milestonePayments.length; i++) {
            totalBudget += job.milestonePayments[i];
        }

        // Determine status code for backward compatibility
        uint256 statusCode;
        if (job.isCompleted) {
            statusCode = 2; // Completed
        } else if (!job.isOpen && job.selectedApplicant != address(0)) {
            statusCode = 1; // In progress
        } else if (job.isOpen) {
            statusCode = 0; // Open
        } else {
            statusCode = 3; // Cancelled
        }

        return (
            job.id,
            job.jobGiver,
            "", // title (empty for new format)
            "", // description (empty for new format)
            totalBudget,
            0, // deadline (0 for new format)
            job.createdAt,
            job.selectedApplicant,
            statusCode,
            job.isCompleted ? block.timestamp : 0 // completedAt
        );
    }

    /**
     * @dev Get detailed job information
     * @param jobId ID of the job
     * @return id Job ID
     * @return jobGiver Job giver address
     * @return jobDetailHash IPFS hash containing job details
     * @return isOpen Whether the job is open for applications
     * @return isCompleted Whether the job is completed
     * @return selectedApplicant The address of the selected freelancer
     * @return currentMilestone Current milestone index
     * @return totalMilestones Total number of milestones
     * @return totalPaid Total amount paid so far
     * @return applicantCount Number of applicants
     */
    function getJobDetails(uint256 jobId) external view returns (
        uint256 id,
        address jobGiver,
        string memory jobDetailHash,
        bool isOpen,
        bool isCompleted,
        address selectedApplicant,
        uint256 currentMilestone,
        uint256 totalMilestones,
        uint256 totalPaid,
        uint256 applicantCount
    ) {
        require(_jobExists(jobId), "Job does not exist");

        Job storage job = _jobs[jobId];

        return (
            job.id,
            job.jobGiver,
            job.jobDetailHash,
            job.isOpen,
            job.isCompleted,
            job.selectedApplicant,
            job.currentMilestone,
            job.milestonePayments.length,
            job.totalPaid,
            job.applicants.length
        );
    }

    /**
     * @dev Check if an applicant has proposed milestones
     * @param jobId ID of the job
     * @param applicant Address of the applicant
     * @return hasProposal True if the applicant has proposed milestones
     */
    function hasProposedMilestones(uint256 jobId, address applicant) external view returns (bool hasProposal) {
        require(_jobExists(jobId), "Job does not exist");
        return _jobs[jobId].proposedMilestones[applicant].hasMilestoneProposal;
    }

    /**
     * @dev Get proposed milestones from an applicant
     * @param jobId ID of the job
     * @param applicant Address of the applicant
     * @return hasMilestoneProposal Whether the applicant has proposed milestones
     * @return milestonePayments Array of proposed milestone payment amounts
     * @return milestoneDetailsHash IPFS hash containing milestone descriptions
     */
    function getProposedMilestones(uint256 jobId, address applicant) 
        external 
        view 
        returns (
            bool hasMilestoneProposal,
            uint256[] memory milestonePayments,
            string memory milestoneDetailsHash
        ) 
    {
        require(_jobExists(jobId), "Job does not exist");

        ProposedMilestones storage proposal = _jobs[jobId].proposedMilestones[applicant];

        return (
            proposal.hasMilestoneProposal,
            proposal.milestonePayments,
            proposal.milestoneDetailsHash
        );
    }

    /**
     * @dev Lock funds for a disputed job
     * @param jobId ID of the job
     * @param disputeId ID of the dispute
     * @return lockedAmount Amount of funds locked
     */
    function lockDisputedFunds(uint256 jobId, uint256 disputeId) external returns (uint256 lockedAmount) {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(!job.isOpen, "Job must be assigned before locking disputed funds");

        uint256 amountToLock = job.currentLockedAmount;
        job.currentLockedAmount = 0;
        _disputeLockedFunds[disputeId] = amountToLock;

        emit FundsLocked(jobId, disputeId, amountToLock);

        return amountToLock;
    }

    /**
     * @dev Complete a milestone and unlock the next one
     * @param jobId ID of the job
     * @param milestoneIndex Index of the milestone to complete
     */
    function completeMilestone_UnlockNext(uint256 jobId, uint256 milestoneIndex) external {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(_isJobGiver(jobId, msg.sender), "Only job giver can complete milestone");
        require(!job.isCompleted, "Job is already completed");
        require(job.currentMilestone == milestoneIndex, "Can only complete current milestone");

        // Release the currently locked funds
        uint256 amountToRelease = job.currentLockedAmount;
        address freelancer = job.selectedApplicant;

        job.currentLockedAmount = 0;
        job.totalPaid += amountToRelease;

        // Transfer funds to the freelancer
        if (amountToRelease > 0) {
            payable(freelancer).transfer(amountToRelease);

            // Record earnings if earnings contract is set
            if (address(_earningsContract) != address(0)) {
                _earningsContract.recordEarnings(freelancer, amountToRelease);
                emit EarningsRecorded(freelancer, amountToRelease);
            }
        }

        // Emit event for the completed milestone
        emit MilestoneCompleted(jobId, milestoneIndex, amountToRelease);
        emit MilestonePaid(jobId, milestoneIndex, amountToRelease);

        // Check if this was the last milestone
        if (milestoneIndex == job.milestonePayments.length - 1) {
            job.isCompleted = true;
            emit JobCompleted(jobId);
        } else {
            // Prepare for next milestone
            job.currentMilestone++;
            emit NextMilestoneReady(jobId, milestoneIndex + 1, job.milestonePayments[milestoneIndex + 1]);
        }
    }

    /**
     * @dev Start the next milestone and lock the payment
     * @param jobId ID of the job
     */
    function startNextMilestone(uint256 jobId) external payable {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(_isJobGiver(jobId, msg.sender), "Only job giver can start next milestone");
        require(!job.isCompleted, "Job is already completed");
        require(job.currentLockedAmount == 0, "Previous milestone payment still locked");

        uint256 currentMilestone = job.currentMilestone;
        require(currentMilestone < job.milestonePayments.length, "No more milestones");

        uint256 milestonePayment = job.milestonePayments[currentMilestone];
        require(msg.value >= milestonePayment, "Insufficient funds for milestone payment");

        _lockMilestonePayment(jobId, currentMilestone, milestonePayment);

        // Refund excess value if sent
        if (msg.value > milestonePayment) {
            payable(msg.sender).transfer(msg.value - milestonePayment);
        }
    }

    /**
     * @dev Release payment for a milestone on interchain job
     * @param jobId ID of the job
     * @param milestoneIndex Index of the milestone
     * @param amountReleased The amount that was released on the local chain
     */
    function releasePaymentInterchain(uint256 jobId, uint256 milestoneIndex, uint256 amountReleased) external {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(!job.isCompleted, "Job is already completed");
        require(job.currentMilestone == milestoneIndex, "Can only complete current milestone");

        // In interchain payments, the actual payment happens on the local chain
        // We just need to update the state and emit events
        job.totalPaid += amountReleased;

        // Record earnings if earnings contract is set
        if (address(_earningsContract) != address(0)) {
            _earningsContract.recordEarnings(job.selectedApplicant, amountReleased);
            emit EarningsRecorded(job.selectedApplicant, amountReleased);
        }

        // Emit event for the completed milestone
        emit MilestoneCompleted(jobId, milestoneIndex, amountReleased);
        emit MilestonePaid(jobId, milestoneIndex, amountReleased);

        // Check if this was the last milestone
        if (milestoneIndex == job.milestonePayments.length - 1) {
            job.isCompleted = true;
            emit JobCompleted(jobId);
        } else {
            // Prepare for next milestone
            job.currentMilestone++;
            emit NextMilestoneReady(jobId, milestoneIndex + 1, job.milestonePayments[milestoneIndex + 1]);
        }
    }

    /**
     * @dev Lock next milestone payment for interchain job
     * @param jobId ID of the job
     * @param milestoneAmount The amount locked on the local chain
     */
    function lockNextMilestoneInterchain(uint256 jobId, uint256 milestoneAmount) external {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(!job.isCompleted, "Job is already completed");

        uint256 currentMilestone = job.currentMilestone;
        require(currentMilestone < job.milestonePayments.length, "No more milestones");

        // For interchain jobs, the actual locking happens on the local chain
        // We just need to update the state and emit events
        emit MilestoneLocked(jobId, currentMilestone, milestoneAmount);
    }

    /**
     * @dev Get the total milestone amount for a job
     * @param jobId ID of the job
     * @return totalAmount Total amount across all milestones
     */
    function getTotalMilestoneAmount(uint256 jobId) external view returns (uint256 totalAmount) {
        require(_jobExists(jobId), "Job does not exist");

        Job storage job = _jobs[jobId];
        uint256 total = 0;

        for (uint256 i = 0; i < job.milestonePayments.length; i++) {
            total += job.milestonePayments[i];
        }

        return total;
    }

    /**
     * @dev Get the number of milestones for a job
     * @param jobId ID of the job
     * @return count Number of milestones
     */
    function getMilestoneCount(uint256 jobId) external view returns (uint256 count) {
        require(_jobExists(jobId), "Job does not exist");
        return _jobs[jobId].milestonePayments.length;
    }

    /**
     * @dev Get milestone details
     * @param jobId ID of the job
     * @param milestoneIndex Index of the milestone
     * @return amount Payment amount for the milestone
     * @return completed Whether the milestone is completed
     * @return paid Whether the milestone payment has been paid
     */
    function getMilestone(uint256 jobId, uint256 milestoneIndex) external view returns (
        uint256 amount,
        bool completed,
        bool paid
    ) {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(milestoneIndex < job.milestonePayments.length, "Invalid milestone index");

        bool isCompleted = job.currentMilestone > milestoneIndex || job.isCompleted;
        bool isPaid = isCompleted; // In this model, a completed milestone is always paid

        return (
            job.milestonePayments[milestoneIndex],
            isCompleted,
            isPaid
        );
    }

    /**
     * @dev Get the number of applicants for a job
     * @param jobId ID of the job
     * @return count Number of applicants
     */
    function getApplicantCount(uint256 jobId) external view returns (uint256 count) {
        require(_jobExists(jobId), "Job does not exist");
        return _jobs[jobId].applicants.length;
    }

    /**
     * @dev Get an applicant address for a job
     * @param jobId ID of the job
     * @param applicantIndex Index of the applicant
     * @return applicant Address of the applicant
     */
    function getApplicant(uint256 jobId, uint256 applicantIndex) external view returns (address applicant) {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(applicantIndex < job.applicants.length, "Invalid applicant index");

        return job.applicants[applicantIndex];
    }

    /**
     * @dev Get application details for a job
     * @param jobId ID of the job
     * @param applicantIndex Index of the applicant
     * @return applicant Address of the applicant
     * @return proposalHash IPFS hash containing the proposal
     */
    function getApplication(uint256 jobId, uint256 applicantIndex) external view returns (
        address applicant,
        string memory proposalHash
    ) {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(applicantIndex < job.applicants.length, "Invalid applicant index");

        address applicantAddr = job.applicants[applicantIndex];
        return (
            applicantAddr,
            job.proposals[applicantAddr]
        );
    }

    /**
     * @dev Complete a job
     * @param jobId ID of the job
     */
    function completeJob(uint256 jobId) external {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(_isJobGiver(jobId, msg.sender), "Only job giver can complete job");
        require(!job.isCompleted, "Job is already completed");

        job.isCompleted = true;
        emit JobCompleted(jobId);
    }

    /**
     * @dev Create a dispute for a job
     * @param jobId ID of the job
     * @param reason Reason for the dispute
     */
    function createDispute(uint256 jobId, string memory reason) external {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(!job.isCompleted, "Job is already completed");
        require(msg.sender == job.jobGiver || msg.sender == job.selectedApplicant, "Only job giver or freelancer can create dispute");

        // This function just records the dispute. The actual dispute resolution
        // happens through a separate dispute resolution system.
        emit DisputeCreated(jobId, reason, msg.sender);
    }

    /**
     * @dev Resolve a dispute
     * @param jobId ID of the job
     * Note: Parameters favorFreelancer and freelancerShare are commented out in the implementation
     */
    function resolveDispute(uint256 jobId, bool /*favorFreelancer*/, uint8 /*freelancerShare*/) external view {
        require(_jobExists(jobId), "Job does not exist");
        require(msg.sender == owner(), "Only owner can resolve disputes");

        // Simplified dispute resolution mechanism
        // In a real implementation, this would be handled by a more complex governance system
    }

    /**
     * @dev Release disputed funds
     * @param jobId ID of the job
     * @param disputeId ID of the dispute
     * @param winner Address of the winner (as uint256)
     * @param amount Amount to release
     * @param platformFee Platform fee to deduct
     * @return success True if the funds were released
     * Note: Parameter loser is commented out in the implementation
     */
    function releaseDisputedFunds(
        uint256 jobId,
        uint256 disputeId,
        uint256 winner,
        uint256 /*loser*/,
        uint256 amount,
        uint256 platformFee
    ) external returns (bool success) {
        require(msg.sender == owner(), "Only owner can release disputed funds");
        require(_disputeLockedFunds[disputeId] >= amount, "Insufficient locked funds");

        _disputeLockedFunds[disputeId] -= amount;

        // Convert uint256 winner address back to address
        address winnerAddress = address(uint160(winner));

        // Calculate platform fee and winner amount
        uint256 platformAmount = amount * platformFee / 100;
        uint256 winnerAmount = amount - platformAmount;

        // Transfer funds
        if (platformAmount > 0) {
            payable(owner()).transfer(platformAmount);
        }

        if (winnerAmount > 0) {
            payable(winnerAddress).transfer(winnerAmount);

            // Record earnings if winner is freelancer and earnings contract is set
            if (winner == 1 && address(_earningsContract) != address(0)) {
                _earningsContract.recordEarnings(winnerAddress, amount);
                emit EarningsRecorded(winnerAddress, amount);
            }
        }

        emit DisputedFundsReleased(jobId, disputeId, amount);
        return true;
    }

    /**
     * @dev Fund a job
     * @param jobId ID of the job
     */
    function fundJob(uint256 jobId) external payable {
        require(_jobExists(jobId), "Job does not exist");
        Job storage job = _jobs[jobId];
        require(_isJobGiver(jobId, msg.sender), "Only job giver can fund the job");
        require(!job.isCompleted, "Job is already completed");

        emit JobFunded(jobId, msg.value);
    }

    /**
     * @dev Required by UUPSUpgradeable - Only owner can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}