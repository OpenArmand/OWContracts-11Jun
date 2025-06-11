Welcome to the OpenWork Developer Documentation. 

OpenWork is a blockchain-based decentralized work platform that replaces traditional intermediaries by enabling job givers and takers to engage directly through smart contracts, ensuring transparent and immutable records of every work transaction on a blockchain of its own. It also integrates features like skill oracles for objective dispute resolution and a robust tokenomics model for decentralized governance, thereby empowering users to participate in a trustless and fair online labor ecosystem.

In simpler words, OpenWork enables two strangers to safely enter work contracts, pay in crypto, use escrow services, resolve disputes, build reputations, and maintain self-custody of their profiles, all without the need for a centralized authority of any kind.

It features an intuitive interface and smart contracts—usable on preferred chains with a single source of truth for work, OpenWork Chain (an optimistic roll up on Ethereum)—to securely manage job postings, work submissions, escrow, and rewards. Governed by a DAO, OpenWork empowers its community to vote on upgrades, manage funds, and resolve disputes, creating a scalable, trustless ecosystem for on chain work. OpenWork Chain lays the base for programmable decentralised work of the future.


Overview
This page describes OpenWork at a higher level and links to detailed sections

The OpenWork System works across 3 layers of blockchains.

The Main DAO on the Ethereum blockchain which is the decentralised governing body of OpenWork, where voting power is determined by OpenWork tokens held, handling upgrades, managing the OpenWork system  & treasury management but not limited to just that.

The OpenWork Chain is a blockchain (L2 on ethereum) that underpins the entire OpenWork ecosystem. It securely records every work transaction on an immutable ledger dedicated to on-chain work, hosts key native smart contracts like Athena (skill oracles) used for key decentralised functions like dispute resolution. 

The Local OpenWork Contract which enables users to use OpenWork on any preferred blockchain (referred to as a local chain, being local to the user). This contract communicates with the OpenWork chain which acts as a single source of truth to record data and uses its functions like Athena's dispute resolution. For example, users who already use Polygon chain, can use OpenWork on polygon- the OpenWork chain in turn is still used as the back-end. In other words, we've created OpenWork in a way where it's chain-agnostic and designed to accommodate any blockchain the user wants to use it on. Initially, the Local OpenWork Contract will be built on EVM-based chains, and later on non-EVM chains like Solana.

The diagram below represents the higher level architecture of the OpenWork System.


The OpenWork System
The below table describes all the contracts on all chain in brief:

Chain
Name of Contracts
Short description
Ethereum 

Main Token Contract

handles minting/burning and other token specific functions

Ethereum

Main DAO is split into 

1. OpenworkDAO.sol
2. OpenworkGovernor.sol
3. OpenworkTimelock.sol 

OpenworkDAO.sol - handles key proposals, handles upgrades across chains & manages token functions, selects sequencer

OpenworkGovernor.sol - contains the OpenZeppelin GovernorLogic

OpenworkTimelock.sol - independent timelock contract used to delay critical functions


Ethereum

Rewards Payout Contract

handles the payment of rewards after all conditions are met

Ethereum

Bridge Contract

interfaces with all other chains to send/receive data

OpenWork Chain

Native OpenWork Contract is split into 2 files -
1.OpenworkUserRegistry.sol
2. OpenworkJobMarket.sol

contains functions to create a profile, post job, apply to job, submit work, release payments & all other job related functions described in this doc

OpenWork Chain


Rewards Tracking Contract

tracks user rewards and sends the info to Ethereum

OpenWork Chain

Native DAO is split into 2 files - 
1. NativeDAOGovernance.sol

SkillOracleManager.sol

NativeDAOGovernance.sol handles Athena related proposals, voting and penalizing malicious members

SkillOracleManager.sol - has the all Skill Oracle related functionality like disputes,etc.




OpenWork Chain

GovernanceActionTrackerContract.sol

GovernanceActionTrackerContract.sol - tracks all governance actions done by all members across all relevant contracts. Used by the Rewards Payout Contract to calculated eligible payout. 

OpenWork Chain

Native Athena is split into 2 files
1. DisputeOracleEngine.sol
2. SkillQuestionEngine.sol

DisputeOracleEngine.sol - handles voting on disputes and resolution

SkillQuestionEngine.sol  -handles skill verification and questions

OpenWork Chain

Bridge Contract

interfaces with all other chains to send/receive data

Local Chains

Local OpenWork Contract

contains bridged-functions to create a profile, post job, apply to job, submit work, release payments & all other job related functions. Bridged-function are just wrapper functions which don’t do anything other than calling the corresponding functions on the OpenWork chain


Local Chains

Athena Client Contract

has all dispute-resolution related bridged-functions

Local Chains

Bridge Contract

interfaces with all other chains to send/receive data

The below table shows how all key functions work across chains.

Section with Link
Key Functions with Explanations
Profile

setProfile

The unregistered (or registered) user calls the function using UI.
UI pins data to IPFS and gets a hash.
The user then calls the function in the Local OpenWork Contract on their local chain with the generated hash. 

The call is bridged to the Native OpenWork Contract on OpenWork Chain to record the profile.

getProfile

The registered user calls the getProfile function on their local chain using the UI.
The call is bridged to the Native OpenWork Contract on OpenWork Chain to retrieve the profile data (stored as an IPFS hash).
The UI calls IPFS to get the data from stored in the hash.

Jobs

applytoJob

User calls function using UI.
UI pins job application details to IPFS and gets the hash.
The UI calls the function on the Local OpenWork contract on the local chain with the hash.
The call gets bridged to the Native OpenWork Contract on the OpenWork chain.

getJobDetails

The user calls the getJobDetails function on their local chain, and the call is bridged to the Native OpenWork Contract on OpenWork Chain to retrieve detailed information for the specified job.

startJobInterChain

User calls function on Local OpenWork Contract on the local chain through the UI.
Funds are locked in the local chain.
Function call is bridged to the OpenWork chain to update the status of this Job.

release&TerminateJob

The Job Giver calls the  function on their local chain once the work is approved.
The Local OpenWork Contract checks with the Native OpenWork contract whether to release payment.
If everything checks out, payment is released on the local chain.

Athena

raiseDispute

This function is called on the User's local chain.
The dispute fee is locked in the Athena Client contract on the local chain.
The dispute details are sent to the OW chain.

voteonDispute

The Skill Oracle member of a relevant Oracle calls this function on the OpenWork Chain.
Vote is registered in the Native Athena contract on the OW chain.

claimDisputedAmount

This function can be called by the dispute winner on the chain the dispute was raised on.
The disputed amount is sent to the dispute winner on the same chain.

applyForSkillOracle

A DAO member with atleast 100k tokens can call this function on the Native Athena Contract on the OW chain.

A proposal gets created in the DAO.
This proposal then go through a voting process and if the vote is passed the applicant is added to the specified Skill Oracle

DAO

joinDAO

This function can be called by anyone on the Ethereum with atleast 100k OW tokens.
The specified amount is staked for the specified period and the user is added to the list of DAO members.

getStake

This function(in the Main DAO on Ethereum) will be mainly called by the contracts on all chains to verify if a caller is a DAO member or not and the amount he has staked. But it can be called by anybody.

propose

The user (an eligible DAO member) calls the propose function on the mainDAO Contract on Ethereum via the UI to submit a proposal, which is compatible with Governor-style voting.

voteonProposal

Any DAO member calls the voteonProposal function on the Main DAO Contract on Ethereum via the UI to cast a vote on an active proposal, with votes weighted by staked tokens + duration of staking, and the result is recorded on-chain.

redeemTokens

The user calls the claimRewards function on the Main DAO contract on Ethereum via the UI to initiate the unstaking process, with tokens unlocked after the unbonding period (e.g., 14 days).
