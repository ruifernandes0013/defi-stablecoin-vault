// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.26;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author Rui Fernandes
 * Collateral: wETH or wBTC
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 *
 * This is the contract meant to be governed by CVSEngine. This contract is just the ERC20 implementation
 * of our stablecoin system
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
  error DecentralizedStableCoin_MustBeMoreThanZero();
  error DecentralizedStableCoin_BurnAmountExceedsBalance();
  error DecentralizedStableCoin_NotZeroAddress();

  constructor() ERC20("DecentralizedStableCoin", "CVS") Ownable(msg.sender) {}

  function burn(uint256 _amount) public override onlyOwner {
    uint256 balance = balanceOf(msg.sender);
    if (_amount <= 0) {
      revert DecentralizedStableCoin_MustBeMoreThanZero();
    }

    if (balance < _amount) {
      revert DecentralizedStableCoin_BurnAmountExceedsBalance();
    }

    super.burn(_amount);
  }

  function mint(
    address _to,
    uint256 _amount
  ) external onlyOwner returns (bool) {
    if (_to == address(0)) {
      revert DecentralizedStableCoin_NotZeroAddress();
    }
    if (_amount <= 0) {
      revert DecentralizedStableCoin_MustBeMoreThanZero();
    }

    _mint(_to, _amount);
    return true;
  }
}
