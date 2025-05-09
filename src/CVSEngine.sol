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

/**
 * @title Variable Glossary (Developer Reference)
 *
 * This section documents all state variables used in the CVSEngine contract
 * to provide a clear overview of their purpose and naming conventions.
 *
 * Naming Conventions:
 *  - `s_` prefix: Denotes a storage (state) variable
 *  - `i_` prefix: Denotes an immutable variable set at deployment
 *
 * Variables:
 *
 * - s_priceFeeds:
 *     Mapping from allowed collateral token addresses to their Chainlink price feed addresses.
 *     Used to fetch real-time USD value of each collateral type.
 *
 * - s_vaults:
 *     Nested mapping tracking each user's collateral and debt per token.
 *     Format: user address => token address => Vault struct.
 *     Vault struct includes:
 *       - collateralAmount: Total collateral deposited by the user for that token
 *       - debt: Total CVS tokens minted (owed) against that collateral
 *
 * - s_collateralAddresses:
 *     Dynamic array of all supported collateral token addresses.
 *     Used for enumeration and validation.
 *
 * - i_cvsToken:
 *     Immutable reference to the CVS stablecoin contract.
 *     Used for minting and burning CVS tokens during engine operations.
 */
pragma solidity ^0.8.26;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

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
  error CVSEngine_MaxAvailableTokensToMintExceed(uint256 hf, uint256 precision);
  //////////////////////
  // State Variables //
  //////////////////////

  mapping(address collateralAddress => address priceFeed) private s_priceFeeds;
  mapping(address user => mapping(address collateralAddress => uint256 collateralAmount))
    private s_collateralDeposited;

  mapping(address user => uint256 amountInCvs) private s_CvsMinted;
  address[] private s_collateralAddresses;

  DecentralizedStableCoin private immutable i_cvsToken;

  uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
  uint256 private constant PRECISION = 1e18;
  uint256 private constant LIQUIDATION_THRESHOLD = 50;
  uint256 private constant LIQUIDATION_PRECISION = 100;

  //////////////////////
  /// Events         ///
  //////////////////////
  event CollateralDeposited(
    address indexed user,
    address indexed collateralAddress,
    uint256 indexed collateralAmount
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

  modifier isAllowedCollateral(address collateralAddress) {
    if (s_priceFeeds[collateralAddress] == address(0)) {
      revert CVSEngine_CollateralTokenNotAllowed();
    }
    _;
  }

  //////////////////////
  /// Functions      ///
  //////////////////////
  constructor(
    address[] memory collateralAddress,
    address[] memory priceFeed,
    address cvsTokenAddress
  ) {
    if (collateralAddress.length != priceFeed.length) {
      revert CVSEngine_TokenAddressesMustMatchPriceFeeds();
    }

    for (uint256 i = 0; i < collateralAddress.length; i++) {
      s_priceFeeds[collateralAddress[i]] = priceFeed[i];
      s_collateralAddresses.push(collateralAddress[i]);
    }

    i_cvsToken = DecentralizedStableCoin(cvsTokenAddress);
  }

  //////////////////////
  //External Functions//
  //////////////////////
  /**
   * @notice Deposits collateral and mints CVS tokens in a single transaction.
   * @param collateralAddress The ERC20 token address to be deposited (must be allowed).
   * @param collateralAmount Amount of collateral to deposit.
   * @param amountCvsToMint Amount of CVS tokens to mint.
   * @dev This combines collateral deposit and minting for user convenience.
   */
  function depositCollateralAndMintCvs(
    address collateralAddress,
    uint256 collateralAmount,
    uint256 amountCvsToMint
  ) external {
    depositCollateral(collateralAddress, collateralAmount);
    mintCvs(amountCvsToMint);
  }

  /**
   * @notice Placeholder for redeeming collateral by returning CVS tokens.
   * @dev Not yet implemented.
   */
  function redeemCollateralForCvs() external {}

  /**
   * @notice Placeholder for withdrawing collateral (no CVS involved).
   * @dev Not yet implemented.
   */
  function redeemCollateral() external {}

  /**
   * @notice Placeholder for burning CVS tokens to reduce debt.
   * @dev Not yet implemented.
   */
  function burnCvs() external {}

  /**
   * @notice Placeholder for liquidating unhealthy positions.
   * @dev Not yet implemented.
   */
  function liquidate() external {}

  //////////////////////
  //Public Functions//
  //////////////////////

  //////////////////////
  //Internal Functions//
  //////////////////////

  /**
   * @notice Allows a user to deposit collateral into the protocol
   * @notice Follows the CEI pattern (Checks, Effects, Interations)
   *  - Checks are the modifiers
   *  - Effects are the events
   *  - And external interactions is whith the ERC20 tokens
   * @param collateralAddress The address of the ERC20 token being used as collateral (e.g., wETH or wBTC)
   * @param collateralAmount The amount of collateral to deposit
   *
   * Requirements:
   * - collateralAddress must be a supported collateral asset
   * - collateralAmount must be greater than zero
   * - The user must approve the protocol to transfer the specified amount before calling
   *
   * Effects:
   * - Transfers collateral from user to protocol
   * - Updates internal accounting to track deposited collateral per user
   */
  function depositCollateral(
    address collateralAddress,
    uint256 collateralAmount
  )
    internal
    moreThanZero(collateralAmount)
    isAllowedCollateral(collateralAddress)
    nonReentrant // reentrant is the most comman attacks in web3
  {
    bool success = IERC20(collateralAddress).transferFrom(
      msg.sender,
      address(this),
      collateralAmount
    );

    if (!success) {
      revert CVSEngine_TokenTransferFailed();
    }

    s_collateralDeposited[msg.sender][collateralAddress] += collateralAmount;
    emit CollateralDeposited(msg.sender, collateralAddress, collateralAmount);
  }

  /**
   * @notice Mints CVS tokens to the user based on their account's health factor.
   * @notice Follows the CEI pattern (Checks, Effects, Interations)
   * @param amountToMint Amount of CVS tokens the user wants to mint.
   * @dev Updates user debt, checks health factor, and mints tokens if safe.
   */
  function mintCvs(
    uint256 amountToMint
  ) internal moreThanZero(amountToMint) nonReentrant {
    s_CvsMinted[msg.sender] += amountToMint;
    _revertIfHealthFactorIsBroken(msg.sender);

    bool success = i_cvsToken.mint(msg.sender, amountToMint);
    if (!success) {
      revert CVSEngine_TokenTransferFailed();
    }
  }

  //////////////////////
  //private functions//
  //////////////////////
  /**
   * @notice Reverts if the user's health factor falls below 1.0 (PRECISION).
   * @param user The address of the account to check.
   */
  function _revertIfHealthFactorIsBroken(address user) private view {
    uint256 hf = _healthFactor(user);
    if (hf < PRECISION) {
      revert CVSEngine_MaxAvailableTokensToMintExceed(hf, PRECISION);
    }
  }

  /**
   * @notice Computes the health factor of a user.
   * @param user The address of the user.
   * @return A scaled health factor (1e18 = safe; <1e18 = unhealthy).
   */
  function _healthFactor(address user) private view returns (uint256) {
    uint256 collateralInUsd = getAccountCollateralValueInUSD(user);
    uint256 debt = s_CvsMinted[user];

    if (debt == 0) return type(uint256).max;
    uint256 collateralAdjustedForThreshold = (collateralInUsd *
      LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

    return (collateralAdjustedForThreshold * PRECISION) / debt;
  }

  //////////////////////
  //view & pure functions//
  //////////////////////

  /**
   * @notice Returns the total USD value of a user’s deposited collateral across all allowed tokens.
   * @param user The address of the user.
   * @return collateralInUsd Total collateral value in USD.
   */
  function getAccountCollateralValueInUSD(
    address user
  ) public view returns (uint256 collateralInUsd) {
    for (uint256 index = 0; index < s_collateralAddresses.length; index++) {
      address collateralAddress = s_collateralAddresses[index];
      uint256 collateralAmount = s_collateralDeposited[user][collateralAddress];

      address priceFeed = s_priceFeeds[collateralAddress];
      collateralInUsd += getUsdValue(priceFeed, collateralAmount);
    }
  }

  /**
   * @notice Converts an amount of a token to its USD equivalent using Chainlink feed.
   * @param priceFeed Chainlink AggregatorV3Interface for the token.
   * @param collateralAmount Amount of the token. (must have 18 decimals)
   * @return collateralInUsd USD equivalent of the token amount. (with 18 decimals)
   */
  function getUsdValue(
    address priceFeed,
    uint256 collateralAmount
  ) public view returns (uint256 collateralInUsd) {
    AggregatorV3Interface priceFeedAgg = AggregatorV3Interface(priceFeed);
    (, int256 answer, , , ) = priceFeedAgg.latestRoundData();

    uint256 usdPrice = uint256(answer) * ADDITIONAL_FEED_PRECISION;
    collateralInUsd = (collateralAmount * usdPrice) / PRECISION;
  }

  /**
   * @notice Converts a USD amount to CVS tokens using the collateralization ratio.
   *          (all with 18 decimals)
   * @param amountInUsd The USD value.
   * @return amountInCvs Corresponding CVS token amount that can be minted.
   */
  function convertToCvs(
    uint256 amountInUsd
  ) public pure returns (uint256 amountInCvs) {
    // amountInUsd * 100 / MIN_COLLATERAL_RATIO avoids floating points
    amountInCvs = (amountInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
  }

  /**
   * @notice Returns the amount of CVS tokens minted by a user.
   * @param user The address of the user.
   * @return cvsMinted Amount of minted CVS.
   */
  function getCvsMinted(address user) public view returns (uint256 cvsMinted) {
    cvsMinted = s_CvsMinted[user];
  }

  /**
   * @notice Returns the amount of a specific collateral token deposited by a user.
   * @param user The address of the user.
   * @param collateralAddress The address of the collateral token.
   * @return collateral Amount of collateral token deposited.
   */
  function getCollateralAmountByToken(
    address user,
    address collateralAddress
  ) public view returns (uint256 collateral) {
    collateral = s_collateralDeposited[user][collateralAddress];
  }

  /**
   * @notice Human-readable health status of the user.
   * @param user The address of the user.
   * @return "Healthy" or "Not Healthy" based on the health factor.
   */
  function isHealthy(address user) public view returns (string memory) {
    uint256 hf = _healthFactor(user);
    return hf < PRECISION ? "Not Healthy" : "Healthy";
  }
}
