// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC5805.sol";
import "./interfaces/IOpenWorkDAO.sol";

/**
 * @title OpenWorkGovernor
 * @dev Governance contract for the OpenWork ecosystem
 * Uses the OpenWorkDAO for voting power and the OpenWorkTimelock for executing proposals
 */
contract OpenWorkGovernor is 
    Initializable, 
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorTimelockControlUpgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    // State variables
    address public openWorkDAO;
    
    // Constants
    uint256 public constant PROPOSAL_THRESHOLD = 1_000_000 * 10**18;
    
    /**
     * @dev Initializer for OpenWorkGovernor
     * @param initialOwner Address of the initial owner
     */
    function initialize(
        address initialOwner
    ) initializer public {
        __Governor_init("OpenWorkGovernor");
        __GovernorSettings_init(1, 50400, PROPOSAL_THRESHOLD); // 1 block delay, ~7 days voting period
        __GovernorCountingSimple_init();
        __GovernorVotes_init(IERC5805(address(0))); // Will be set later
        __GovernorTimelockControl_init(TimelockControllerUpgradeable(payable(address(0)))); // Will be set later
        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);
        
        openWorkDAO = address(0); // Will be set later
    }
    
    /**
     * @dev Override of the propose function to record governance actions
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256) {
        // Record governance action
        IOpenWorkDAO(openWorkDAO).recordGovernanceAction(msg.sender);
        
        return super.propose(targets, values, calldatas, description);
    }
    
    /**
     * @dev Override of the castVote function to record governance actions
     */
    function castVote(
        uint256 proposalId, 
        uint8 support
    ) public override returns (uint256) {
        // Record governance action
        IOpenWorkDAO(openWorkDAO).recordGovernanceAction(msg.sender);
        
        return super.castVote(proposalId, support);
    }
    
    /**
     * @dev Override of the castVoteWithReason function to record governance actions
     */
    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) public override returns (uint256) {
        // Record governance action
        IOpenWorkDAO(openWorkDAO).recordGovernanceAction(msg.sender);
        
        return super.castVoteWithReason(proposalId, support, reason);
    }
    
    /**
     * @dev Override of the castVoteBySig function to record governance actions
     */
    function castVoteBySig(
        uint256 proposalId,
        uint8 support,
        address voter,
        bytes memory signature
    ) public override returns (uint256) {
        // Record governance action
        IOpenWorkDAO(openWorkDAO).recordGovernanceAction(voter);
        
        return super.castVoteBySig(proposalId, support, voter, signature);
    }
    
    /**
     * @dev Overriden quorum function to use the DAO's voting power
     */
    function quorum(uint256 blockNumber) public view override returns (uint256) {
        // Simple implementation: 4% of total voting power
        return token().getPastTotalSupply(blockNumber) * 4 / 100;
    }
    
    /**
     * @dev Function to set proposal threshold
     */
    function proposalThreshold() public pure override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return PROPOSAL_THRESHOLD;
    }
    
    /**
     * @dev Function to get voting delay
     */
    function votingDelay() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingDelay();
    }
    
    /**
     * @dev Function to get voting period
     */
    function votingPeriod() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingPeriod();
    }
    
    /**
     * @dev Function to get the state of a proposal
     */
    function state(uint256 proposalId) public view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (ProposalState) {
        return super.state(proposalId);
    }
    
    /**
     * @dev Function to execute operations
     */
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }
    
    /**
     * @dev Function to queue operations
     */
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }
    
    /**
     * @dev Function to check if proposal needs queuing
     */
    function proposalNeedsQueuing(uint256 proposalId) public view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }
    
    /**
     * @dev Function to cancel a proposal
     */
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }
    
    /**
     * @dev Function to get the executor address
     */
    function _executor() internal view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (address) {
        return super._executor();
    }
    
    /**
     * @dev See {IERC165-supportsInterface}
     */
    function supportsInterface(bytes4 interfaceId) public view override(GovernorUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
    
    /**
     * @dev Enhanced vote counting that includes DAO voting power
     * Override the internal vote counting to add DAO-based voting weight
     */
    function _getVotes(
        address account,
        uint256 blockNumber,
        bytes memory params
    ) internal view override(GovernorUpgradeable, GovernorVotesUpgradeable) returns (uint256) {
        uint256 tokenVotes = super._getVotes(account, blockNumber, params);
        
        // Check if the account can vote in governance based on team tokens or staked tokens
        bool canVote = IOpenWorkDAO(openWorkDAO).canVoteInGovernance(account);
        if (!canVote && tokenVotes == 0) {
            return 0;
        }
        
        // Get additional voting power from DAO if applicable
        uint256 daoVotingPower = IOpenWorkDAO(openWorkDAO).getVotingPower(account);
        return tokenVotes + daoVotingPower;
    }
    
    /**
     * @dev Function to set the DAO address after initialization
     * @param _dao The address of the OpenWorkDAO contract
     */
    function setDAOAddress(address _dao) external onlyOwner {
        require(_dao != address(0), "OpenWorkGovernor: DAO address cannot be zero");
        openWorkDAO = _dao;
    }
    
    /**
     * @dev Function to set the token address for voting
     * @param _token The address of the voting token contract
     */
    function setVotingToken(address _token) external onlyOwner {
        require(_token != address(0), "OpenWorkGovernor: Token address cannot be zero");
        // Update the token reference in GovernorVotes
        __GovernorVotes_init(IERC5805(_token));
    }
    
    /**
     * @dev Function to set the timelock controller address
     * @param _timelock The address of the timelock controller
     */
    function setTimelockController(address _timelock) external onlyOwner {
        require(_timelock != address(0), "OpenWorkGovernor: Timelock address cannot be zero");
        // Update the timelock reference in GovernorTimelockControl
        __GovernorTimelockControl_init(TimelockControllerUpgradeable(payable(_timelock)));
    }
    
    /**
     * @dev Function to update voting delay
     * @param newVotingDelay New voting delay in blocks
     */
    function updateVotingDelay(uint48 newVotingDelay) external onlyOwner {
        _setVotingDelay(newVotingDelay);
    }
    
    /**
     * @dev Function to update voting period
     * @param newVotingPeriod New voting period in blocks
     */
    function updateVotingPeriod(uint32 newVotingPeriod) external onlyOwner {
        _setVotingPeriod(newVotingPeriod);
    }
    
    /**
     * @dev Function to update proposal threshold
     * @param newProposalThreshold New proposal threshold in tokens
     */
    function updateProposalThreshold(uint256 newProposalThreshold) external onlyOwner {
        _setProposalThreshold(newProposalThreshold);
    }
    
    /**
     * @dev Function to authorize an upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}