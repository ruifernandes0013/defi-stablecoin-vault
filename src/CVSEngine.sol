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

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title CVSEngine
 * @author Rui Fernandes
 *
 * This is designed to be as minimal as possible and have the tokens maintain a
 * 1 token = $1 peg
 * This stablecoin has the properties:
 *  - Exogenous Collateral
 *  - Dollar Pegged
 *  - Algorithmically Stable
 *
 * Its similar to DAI if DAI had no governance, no fees, and was only backed by
 * wETH and wBTC
 *
 * Our CVS system must always be "overcollateralzied". At no point, should the
 * value of all collateral <= the $ backed value of all the CVS
 *
 * @notice This contract is the core of the CVS System. It handles the logic
 * for minting and burning CVS, as well as depositing & withdrawing collateral
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract CVSEngine is ReentrancyGuard {
  //////////////////////
  /// Errors         ///
  //////////////////////
  error CVSEngine_AmountMustBeHigherThanZero();
  error CVSEngine_CollateralTokenNotAllowed();
  error CVSEngine_TokenAddressesMustMatchPriceFeeds();
  error CVSEngine_TokenTransferFailed();
  //////////////////////
  // Type Declarations//
  //////////////////////
  struct Vault {
    uint256 collateralAmount;
    uint256 debt;
  }
  //////////////////////
  // State Variables //
  //////////////////////
  mapping(address token => address priceFeed) private s_priceFeeds;
  mapping(address user => mapping(address collateralAddress => Vault vault))
    private s_vaults;

  DecentralizedStableCoin private immutable i_cvsToken;

  //////////////////////
  /// Events         ///
  //////////////////////
  event CollateralDeposited(
    address indexed user,
    address indexed token,
    uint256 indexed amount
  );
  //////////////////////
  /// Modifiers       ///
  //////////////////////
  modifier moreThanZero(uint256 amount) {
    if (amount <= 0) {
      revert CVSEngine_AmountMustBeHigherThanZero();
    }
    _;
  }

  modifier isAllowedCollateral(address tokenAddress) {
    if (s_priceFeeds[tokenAddress] == address(0)) {
      revert CVSEngine_CollateralTokenNotAllowed();
    }
    _;
  }

  //////////////////////
  /// Functions      ///
  //////////////////////
  constructor(
    address[] memory tokenAddress,
    address[] memory priceFeed,
    address cvsTokenAddress
  ) {
    if (tokenAddress.length != priceFeed.length) {
      revert CVSEngine_TokenAddressesMustMatchPriceFeeds();
    }

    for (uint256 i = 0; i < tokenAddress.length; i++) {
      s_priceFeeds[tokenAddress[i]] = priceFeed[i];
    }

    i_cvsToken = DecentralizedStableCoin(cvsTokenAddress);
  }

  //////////////////////
  //External Functions//
  //////////////////////

  /**
   * @notice Allows a user to deposit collateral into the protocol
   * @notice Follows the CEI pattern (Checks, Effects, Interations)
   *  - Checks are the modifiers
   *  - Effects are the events
   *  - And external interactions is whith the ERC20 tokens
   * @param tokenCollateralAddress The address of the ERC20 token being used as collateral (e.g., wETH or wBTC)
   * @param collateralAmount The amount of collateral to deposit
   *
   * Requirements:
   * - tokenCollateralAddress must be a supported collateral asset
   * - collateralAmount must be greater than zero
   * - The user must approve the protocol to transfer the specified amount before calling
   *
   * Effects:
   * - Transfers collateral from user to protocol
   * - Updates internal accounting to track deposited collateral per user
   */
  function depositCollateral(
    address tokenCollateralAddress,
    uint256 collateralAmount
  )
    external
    moreThanZero(collateralAmount)
    isAllowedCollateral(tokenCollateralAddress)
    nonReentrant // reentrant is the most comman attacks in web3
  {
    bool success = IERC20(tokenCollateralAddress).transferFrom(
      msg.sender,
      address(this),
      collateralAmount
    );

    if (!success) {
      revert CVSEngine_TokenTransferFailed();
    }

    s_vaults[msg.sender][tokenCollateralAddress]
      .collateralAmount += collateralAmount;
    emit CollateralDeposited(
      msg.sender,
      tokenCollateralAddress,
      collateralAmount
    );
  }

  function depositCollateralAndMintCvs() external {}

  function redeemCollateralForCvs() external {}

  function redeemCollateral() external {}

  function mintCvs() external {}

  function burnCvs() external {}

  function liquidate() external {}

  function getHealthFactor() external view {}
}
