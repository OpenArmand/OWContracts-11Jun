// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import "hardhat/console.sol";
import "./interfaces/IOpenWorkBridge.sol";

/**
 * @title OpenWorkLayerZeroBridge
 * @dev Bridge contract for OpenWork platform using LayerZero protocol
 * Supports Ethereum, Arbitrum, OP Stack chains, and has architecture ready for Solana integration
 */
contract OpenWorkLayerZeroBridge is Ownable, OApp, ReentrancyGuard, IOpenWorkBridge {
    // Known contracts (trusted sources that can send messages)
    mapping(uint32 => mapping(address => bool)) public trustedContracts;
    
    // Receivers (trusted destinations that can receive messages)
    mapping(uint32 => mapping(address => bool)) public trustedReceivers;
    
    // Message version for compatibility and future upgrades
    uint16 public constant MESSAGE_VERSION = 1;
    
    // Event for message sent
    event MessageSent(
        bytes32 indexed messageId,
        uint32 destinationChainId,
        address receiver,
        bytes data
    );
    
    // Event for message received
    event MessageReceived(
        bytes32 indexed messageId,
        uint32 sourceChainId,
        address sender,
        bytes data
    );
    
    // Event for contract trust updated
    event ContractTrustUpdated(
        uint32 chainId,
        address contractAddress,
        bool trusted
    );
    
    // Event for receiver trust updated
    event ReceiverTrustUpdated(
        uint32 chainId,
        address receiverAddress,
        bool trusted
    );
    
    /**
     * @dev Constructor
     * @param _endpoint Address of the LayerZero endpoint
     * @param _owner Address of the initial owner
     */
    constructor(address _endpoint, address _owner) 
        Ownable(_owner)
        OApp(_endpoint, _owner) 
    {
        // OApp handles gas configuration internally
        // No manual gas setup needed in v2
    }
    
    /**
     * @dev Send a message to another chain
     * @param destinationChainId The destination chain ID (LayerZero v2 EID)
     * @param receiver The receiver address on the destination chain
     * @param data The message data
     * @return messageId A unique ID for the message
     */
    function sendMessage(
        uint32 destinationChainId,
        address receiver,
        bytes calldata data
    ) external payable override nonReentrant returns (bytes32 messageId) {
        // Ensure the receiver is trusted
        require(
            trustedReceivers[destinationChainId][receiver],
            "Receiver not trusted"
        );
        
        // Encode the message with destination address and metadata for routing
        bytes memory payload = abi.encode(
            MESSAGE_VERSION,  // Version for future compatibility
            receiver,         // Target receiver address on destination chain
            msg.sender,       // Original sender for traceability
            data              // Actual message payload
        );
        
        // Generate a unique message ID for tracking
        messageId = keccak256(abi.encodePacked(
            block.chainid,         // Source chain ID (EVM chain ID)
            destinationChainId,    // Destination chain ID (LZ EID) 
            msg.sender,            // Original sender
            receiver,              // Target receiver
            data,                  // Payload
            block.timestamp        // Timestamp for uniqueness
        ));
        
        console.log("Sending message to chain:", destinationChainId);
        console.log("Payload length:", payload.length);
        
        // Use default options for now (can be made configurable later)
        bytes memory options = "";
        
        // Send message via LayerZero v2 OApp
        _lzSend(
            destinationChainId,                    // destination EID
            payload,                               // message payload
            options,                               // execution options
            MessagingFee(msg.value, 0),           // messaging fee (native fee, ZRO fee)
            payable(msg.sender)                   // refund address
        );
        
        // Emit event for tracking
        emit MessageSent(messageId, destinationChainId, receiver, data);
        
        return messageId;
    }
    
    /**
     * @dev Implementation of the LayerZero v2 receive function
     * This function is called by the LayerZero endpoint when a message arrives
     * @param _origin Source information including chain ID and sender
     * @param _guid Global unique identifier for the message
     * @param _message The message payload
     * @param _executor The executor address (unused)
     * @param _extraData Additional data (unused)
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override {
        // Log debug info
        console.log("Received message from chain:", _origin.srcEid);
        console.log("Message length:", _message.length);
        
        // Extract sender address from bytes32
        address srcAddressAsAddress = address(uint160(uint256(_origin.sender >> 96)));
        console.log("Source bridge address:", srcAddressAsAddress);
        
        // Verify the source is trusted
        require(
            trustedContracts[_origin.srcEid][srcAddressAsAddress],
            "Source contract not trusted"
        );
        
        // Decode the payload to get the message details
        (uint16 version, address targetReceiver, address originalSender, bytes memory data) = abi.decode(
            _message,
            (uint16, address, address, bytes)
        );
        
        // Verify the message version
        require(version == MESSAGE_VERSION, "Unsupported message version");
        
        // Log the target receiver
        console.log("Target receiver:", targetReceiver);
        
        // Generate a message ID for tracking (using GUID for uniqueness)
        bytes32 messageId = _guid;
        
        // Emit reception event
        emit MessageReceived(messageId, _origin.srcEid, originalSender, data);
        
        // Make sure the target receiver exists and has code
        require(targetReceiver.code.length > 0, "Target receiver has no code");
        
        // Forward the data to the intended receiver contract (updated for v2)
        (bool success, bytes memory returnData) = targetReceiver.call(
            abi.encodeWithSignature(
                "receiveMessage(uint32,address,bytes)",
                _origin.srcEid,
                originalSender,
                data
            )
        );
        
        // Check if the call succeeded
        if (!success) {
            // If there's return data, it might contain the revert reason
            if (returnData.length > 0) {
                // Extract the revert reason and revert with it
                assembly {
                    let returnDataSize := mload(returnData)
                    revert(add(32, returnData), returnDataSize)
                }
            } else {
                revert("Message forwarding failed without reason");
            }
        }
    }
    
    /**
     * @dev Calculate the fee for sending a message
     * @param destinationChainId The destination chain ID (LayerZero v2 EID)
     * @param receiver The receiver address
     * @param data The message data
     * @return fee The calculated fee
     */
    function estimateFee(
        uint32 destinationChainId,
        address receiver,
        bytes calldata data
    ) public view override returns (uint256 fee) {
        // Prepare the payload that will be sent
        bytes memory payload = abi.encode(MESSAGE_VERSION, receiver, msg.sender, data);
        
        // Use default options for fee estimation
        bytes memory options = "";
        
        // Get the fee estimate from LayerZero v2 endpoint
        MessagingFee memory messagingFee = _quote(destinationChainId, payload, options, false);
        
        return messagingFee.nativeFee;
    }
    
    /**
     * @dev Set whether a contract is trusted to send messages
     * @param chainId The chain ID (LayerZero v2 EID)
     * @param contractAddress The contract address
     * @param trusted Whether the contract is trusted
     */
    function setTrustedContract(
        uint32 chainId,
        address contractAddress,
        bool trusted
    ) external override onlyOwner {
        trustedContracts[chainId][contractAddress] = trusted;
        emit ContractTrustUpdated(chainId, contractAddress, trusted);
    }
    
    /**
     * @dev Set whether a receiver is trusted to receive messages
     * @param chainId The chain ID (LayerZero v2 EID)
     * @param receiverAddress The receiver address
     * @param trusted Whether the receiver is trusted
     */
    function setTrustedReceiver(
        uint32 chainId,
        address receiverAddress,
        bool trusted
    ) external override onlyOwner {
        trustedReceivers[chainId][receiverAddress] = trusted;
        emit ReceiverTrustUpdated(chainId, receiverAddress, trusted);
    }
    
    /**
     * @dev Set up a trusted path between this contract and a remote contract
     * Uses LayerZero v2 OApp peer system
     * @param _eid The remote endpoint ID
     * @param _peer The remote bridge address
     */
    function setTrustedRemoteBridge(uint32 _eid, address _peer) external onlyOwner {
        // Convert address to bytes32 for OApp peer system
        bytes32 peerBytes32 = bytes32(uint256(uint160(_peer)));
        
        // Set peer in OApp system
        setPeer(_eid, peerBytes32);
        
        // Also mark this remote bridge as trusted for our application-level trust system
        trustedContracts[_eid][_peer] = true;
        emit ContractTrustUpdated(_eid, _peer, true);
    }
    
    /**
     * @dev Check if a chain is configured with a trusted peer
     * @param _eid The endpoint ID to check
     * @return bool True if a peer is configured for this endpoint
     */
    function isChainConfigured(uint32 _eid) external view returns (bool) {
        return peers[_eid] != bytes32(0);
    }
    
    /**
     * @dev Withdraw any stuck native tokens (ETH)
     * Only callable by the owner
     */
    function withdrawNative() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    /**
     * @dev Fallback function to accept native tokens (ETH)
     */
    receive() external payable {}
}