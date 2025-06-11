// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

/**
 * @title IOpenWorkBridge
 * @dev Interface for cross-chain communication in the OpenWork platform
 */
interface IOpenWorkBridge {
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
    ) external payable returns (bytes32 messageId);
    
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
    ) external view returns (uint256 fee);
    
    /**
     * @dev Set whether a contract is trusted
     * @param chainId The chain ID (LayerZero v2 EID)
     * @param contractAddress The contract address
     * @param trusted Whether the contract is trusted
     */
    function setTrustedContract(
        uint32 chainId,
        address contractAddress,
        bool trusted
    ) external;
    
    /**
     * @dev Set whether a receiver is trusted
     * @param chainId The chain ID (LayerZero v2 EID)
     * @param receiverAddress The receiver address
     * @param trusted Whether the receiver is trusted
     */
    function setTrustedReceiver(
        uint32 chainId,
        address receiverAddress,
        bool trusted
    ) external;
}