// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Psy testnet USDT for bridge testing, not official Tether USD.
contract USDTToken is ERC20, Ownable {
    constructor(address initialHolder, uint256 initialSupply) ERC20("Psy USDT", "pUSDT") Ownable(initialHolder) {
        _mint(initialHolder, initialSupply);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
