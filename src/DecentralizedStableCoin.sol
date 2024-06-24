// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Decentralized Stable Coin
 * @author Adebayo halir Shola
 * collateral: Exogeneous (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 *
 * This contract is mesnt to be governed by DSCEngine.
 * It is just the ERC20 implementation of our stable coin system
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZeroToBurn();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__CantMintToZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZeroToBurn();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__CantMintToZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZeroToBurn();
        }
        _mint(_to, _amount);
        return true;
    }
}
