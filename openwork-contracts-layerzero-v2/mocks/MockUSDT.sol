// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDT
 * @dev Mock USDT contract for testing purposes with easy transfer functionality
 * @notice This contract simulates USDT behavior for development and testing
 */
contract MockUSDT is ERC20, Ownable {
    uint8 private _decimals;
    
    // Events for easy tracking
    event EasyTransfer(address indexed from, address indexed to, uint256 amount);
    event BulkTransfer(address indexed sender, uint256 totalAmount, uint256 recipientCount);
    
    constructor(
        string memory name,
        string memory symbol,
        uint8 tokenDecimals,
        uint256 initialSupply
    ) ERC20(name, symbol) Ownable(msg.sender) {
        _decimals = tokenDecimals;
        _mint(msg.sender, initialSupply * 10**tokenDecimals);
    }
    
    /**
     * @dev Returns the number of decimals used to get its user representation
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
    
    /**
     * @dev Mint new tokens (only owner can mint)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint (in token units, not wei)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount * 10**_decimals);
    }
    
    /**
     * @dev Easy transfer function with token units instead of wei
     * @param to Address to transfer tokens to
     * @param amount Amount of tokens to transfer (in token units, not wei)
     */
    function easyTransfer(address to, uint256 amount) external returns (bool) {
        uint256 actualAmount = amount * 10**_decimals;
        _transfer(msg.sender, to, actualAmount);
        emit EasyTransfer(msg.sender, to, amount);
        return true;
    }
    
    /**
     * @dev Easy transfer from function with token units
     * @param from Address to transfer tokens from
     * @param to Address to transfer tokens to
     * @param amount Amount of tokens to transfer (in token units, not wei)
     */
    function easyTransferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 actualAmount = amount * 10**_decimals;
        _transfer(from, to, actualAmount);
        
        uint256 currentAllowance = allowance(from, msg.sender);
        require(currentAllowance >= actualAmount, "MockUSDT: transfer amount exceeds allowance");
        _approve(from, msg.sender, currentAllowance - actualAmount);
        
        emit EasyTransfer(from, to, amount);
        return true;
    }
    
    /**
     * @dev Bulk transfer to multiple addresses with same amount
     * @param recipients Array of addresses to transfer tokens to
     * @param amount Amount of tokens to transfer to each address (in token units)
     */
    function bulkTransfer(address[] calldata recipients, uint256 amount) external returns (bool) {
        uint256 actualAmount = amount * 10**_decimals;
        uint256 totalAmount = actualAmount * recipients.length;
        
        require(balanceOf(msg.sender) >= totalAmount, "MockUSDT: insufficient balance for bulk transfer");
        
        for (uint256 i = 0; i < recipients.length; i++) {
            _transfer(msg.sender, recipients[i], actualAmount);
            emit EasyTransfer(msg.sender, recipients[i], amount);
        }
        
        emit BulkTransfer(msg.sender, amount * recipients.length, recipients.length);
        return true;
    }
    
    /**
     * @dev Bulk transfer with different amounts to different addresses
     * @param recipients Array of addresses to transfer tokens to
     * @param amounts Array of amounts to transfer to each address (in token units)
     */
    function bulkTransferDifferentAmounts(
        address[] calldata recipients, 
        uint256[] calldata amounts
    ) external returns (bool) {
        require(recipients.length == amounts.length, "MockUSDT: arrays length mismatch");
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i] * 10**_decimals;
        }
        
        require(balanceOf(msg.sender) >= totalAmount, "MockUSDT: insufficient balance for bulk transfer");
        
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 actualAmount = amounts[i] * 10**_decimals;
            _transfer(msg.sender, recipients[i], actualAmount);
            emit EasyTransfer(msg.sender, recipients[i], amounts[i]);
        }
        
        emit BulkTransfer(msg.sender, totalAmount / 10**_decimals, recipients.length);
        return true;
    }
    
    /**
     * @dev Get balance in token units instead of wei
     * @param account Address to check balance for
     */
    function balanceInTokens(address account) external view returns (uint256) {
        return balanceOf(account) / 10**_decimals;
    }
    
    /**
     * @dev Approve tokens in token units instead of wei
     * @param spender Address to approve tokens for
     * @param amount Amount of tokens to approve (in token units)
     */
    function easyApprove(address spender, uint256 amount) external returns (bool) {
        uint256 actualAmount = amount * 10**_decimals;
        _approve(msg.sender, spender, actualAmount);
        return true;
    }
    
    /**
     * @dev Faucet function for easy testing - gives tokens to any address
     * @param amount Amount of tokens to give (in token units)
     */
    function faucet(uint256 amount) external {
        _mint(msg.sender, amount * 10**_decimals);
    }
    
    /**
     * @dev Owner can give tokens to any address for testing
     * @param to Address to give tokens to
     * @param amount Amount of tokens to give (in token units)
     */
    function giveTokens(address to, uint256 amount) external onlyOwner {
        _mint(to, amount * 10**_decimals);
    }
}