// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title OpenWorkToken
 * @dev ERC20 token with voting capabilities for the OpenWork ecosystem
 */
contract OpenWorkToken is ERC20Votes, Ownable {
    /**
     * @dev Constructor
     * @param name Token name
     * @param symbol Token symbol
     * @param initialSupply Initial token supply
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address initialOwner
    ) ERC20(name, symbol) EIP712(name, "1") Ownable(initialOwner) {
        _mint(msg.sender, initialSupply);
    }
    
    /**
     * @dev Mint new tokens (can only be called by the owner)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
    
    /**
     * @dev Required override for ERC20Votes to track voting power.
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Votes)
    {
        super._update(from, to, value);
    }


}