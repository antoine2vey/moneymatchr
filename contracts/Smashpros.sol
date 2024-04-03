// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract Smashpros is ERC20, Ownable, ERC20Permit {
    constructor(address initialOwner)
        ERC20("Smashpros", "SMSH")
        Ownable(initialOwner)
        ERC20Permit("Smashpros")
    {
        mint(initialOwner, 1_000_000_000);
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}
