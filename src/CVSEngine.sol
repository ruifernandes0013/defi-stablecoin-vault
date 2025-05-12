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
import {OracleLib} from "./lib/OracleLib.sol";

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
  using OracleLib for AggregatorV3Interface;
  //////////////////////
  /// Errors         ///
  //////////////////////
  error CVSEngine_AmountMustBeHigherThanZero();
  error CVSEngine_CollateralTokenNotAllowed();
  error CVSEngine_TokenAddressesMustMatchPriceFeeds();
  error CVSEngine_TokenTransferFailed();
  error CVSEngine_CantLiquidateHealthyUser();
  error CVSEngine__HealthFactorNotImproved();
  error CVSEngine_HealthFactorTooLow(uint256 hf, uint256 precision);
  //////////////////////
  // State Variables //
  //////////////////////

  mapping(address collateralAddress => address priceFeed) private s_priceFeeds;
  mapping(address user => mapping(address collateralAddress => uint256 collateralAmount))
    private s_collateralDeposited;

  mapping(address user => uint256 amountInCvs) private s_cvsMinted;
  address[] private s_collateralAddresses;

  DecentralizedStableCoin private immutable i_cvsToken;

  uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
  uint256 private constant PRECISION = 1e18;
  uint256 private constant MIN_HEALTH_FACTOR = 1e18;
  uint256 private constant LIQUIDATION_THRESHOLD = 50;
  uint256 private constant LIQUIDATION_PRECISION = 100;
  uint256 private constant LIQUIDATION_BONUS = 10;

  //////////////////////
  /// Events         ///
  //////////////////////
  event CollateralDeposited(
    address indexed user,
    address indexed collateralAddress,
    uint256 indexed collateralAmount
  );
  event CollateralRedeemed(
    address indexed from,
    address indexed to,
    address collateralAddress,
    uint256 collateralAmount
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
   * @notice Burns CVS tokens and redeems a portion of collateral in a single operation.
   * @dev Helps maintain or improve the user's health factor by reducing debt and collateral together.
   * @param collateralAddress The address of the collateral token to redeem.
   * @param collateralAmount The amount of collateral to redeem.
   * @param amountCvsToBurn The amount of CVS to burn before redeeming collateral.
   */
  function redeemCollateralForCvs(
    address collateralAddress,
    uint256 collateralAmount,
    uint256 amountCvsToBurn
  )
    external
    moreThanZero(collateralAmount) // Revert if amount is zero.
    isAllowedCollateral(collateralAddress) // Ensure token is whitelisted.
    nonReentrant // Prevent reentrancy attacks.
  {
    _burnCvs(amountCvsToBurn, msg.sender, msg.sender);
    _redeemCollateral(
      collateralAddress,
      collateralAmount,
      msg.sender,
      msg.sender
    );
    _revertIfHealthFactorIsBroken(msg.sender);
  }

  /**
   * @notice Allows a user to redeem (withdraw) a portion of their deposited collateral.
   * @dev Ensures the user's health factor remains above the liquidation threshold after withdrawal.
   * @param collateralAddress The address of the collateral token to redeem.
   * @param collateralAmount The amount of collateral to redeem.
   */
  function redeemCollateral(
    address collateralAddress,
    uint256 collateralAmount
  )
    external
    moreThanZero(collateralAmount) // Revert if amount is zero.
    isAllowedCollateral(collateralAddress) // Ensure token is whitelisted.
    nonReentrant // Prevent reentrancy attacks.
  {
    _redeemCollateral(
      collateralAddress,
      collateralAmount,
      msg.sender,
      msg.sender
    );
    _revertIfHealthFactorIsBroken(msg.sender);
  }

  function burnCvs(uint256 amount) external moreThanZero(amount) nonReentrant {
    _burnCvs(amount, msg.sender, msg.sender);
    _revertIfHealthFactorIsBroken(msg.sender);
  }

  /**
   * @notice Allows anyone to liquidate a user's undercollateralized position.
   * @param collateralAddress The ERC20 collateral token used by the undercollateralized user.
   * @param user The user whose position is being liquidated.
   * @param debtToCover Amount of CVS the liquidator will repay on behalf of the user.
   *
   * Requirements:
   * - User must be undercollateralized (health factor < MIN_HEALTH_FACTOR).
   * - Liquidator must approve `debtToCover` CVS for this contract.
   *
   * Effects:
   * - Burns CVS from liquidator.
   * - Transfers collateral from user to liquidator (including a liquidation bonus).
   * - Ensures the user's health factor improves post-liquidation.
   * - Ensures liquidator's health factor remains valid.
   */
  function liquidate(
    address collateralAddress,
    address user,
    uint256 debtToCover
  ) external moreThanZero(debtToCover) nonReentrant {
    uint256 startingUserHealthFactor = _healthFactor(user);
    if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
      revert CVSEngine_CantLiquidateHealthyUser();
    }

    uint256 collateralAmount = convertUsdToCollateral(
      collateralAddress,
      debtToCover
    );

    collateralAmount +=
      (collateralAmount * LIQUIDATION_BONUS) /
      LIQUIDATION_PRECISION;

    _redeemCollateral(collateralAddress, collateralAmount, user, msg.sender);
    _burnCvs(debtToCover, user, msg.sender);

    uint256 endingUserHealthFactor = _healthFactor(user);
    if (endingUserHealthFactor <= startingUserHealthFactor) {
      revert CVSEngine__HealthFactorNotImproved();
    }
    _revertIfHealthFactorIsBroken(msg.sender);
  }

  //////////////////////
  //Public Functions//
  //////////////////////
  /**
   * @notice Mints CVS tokens to the user based on their account's health factor.
   * @notice Follows the CEI pattern (Checks, Effects, Interations)
   * @param amountToMint Amount of CVS tokens the user wants to mint.
   * @dev Updates user debt, checks health factor, and mints tokens if safe.
   *
   * Requirements:
   * - Caller must maintain a healthy position post-mint (health factor >= 1).
   * - CVS token minting must succeed.
   *
   * Effects:
   * - Increases user debt.
   * - Mints CVS to user.
   */
  function mintCvs(
    uint256 amountToMint
  ) public moreThanZero(amountToMint) nonReentrant {
    s_cvsMinted[msg.sender] += amountToMint;
    _revertIfHealthFactorIsBroken(msg.sender);

    bool success = i_cvsToken.mint(msg.sender, amountToMint);
    if (!success) {
      revert CVSEngine_TokenTransferFailed();
    }
  }

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
    public
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

  //////////////////////
  //private functions//
  //////////////////////
  /**
   * @notice Internal function to transfer collateral back to the user.
   * @dev Subtracts from internal accounting and sends the token using `transfer`.
   * @param collateralAddress The address of the ERC20 token being redeemed.
   * @param collateralAmount The amount of tokens to redeem.
   * @param from The user whose balance is being reduced.
   * @param to The user receiving the collateral (could be a liquidator or the user themselves).
   *
   * Requirements:
   * - Caller must ensure `collateralAmount` is available in `from`'s balance.
   * - Health factor checks should be performed after calling this function externally.
   *
   * Effects:
   * - Decreases deposited collateral.
   * - Emits `CollateralRedeemed`.
   */
  function _redeemCollateral(
    address collateralAddress,
    uint256 collateralAmount,
    address from,
    address to
  ) private {
    s_collateralDeposited[from][collateralAddress] -= collateralAmount;
    emit CollateralRedeemed(from, to, collateralAddress, collateralAmount);

    bool success = IERC20(collateralAddress).transfer(to, collateralAmount);
    if (!success) {
      revert CVSEngine_TokenTransferFailed();
    }
  }

  /**
   * @notice Reverts if the user's health factor falls below 1.0 (PRECISION).
   * @param user The address of the account to check.
   */
  function _revertIfHealthFactorIsBroken(address user) private view {
    uint256 hf = _healthFactor(user);
    if (hf < PRECISION) {
      revert CVSEngine_HealthFactorTooLow(hf, PRECISION);
    }
  }

  /**
   * @notice Internal function to burn CVS tokens and reduce user's debt.
   * @param amountToBurn Amount of CVS tokens to burn.
   * @param onBehalfOf Address whose debt will be reduced.
   * @param cvsFrom Address providing the CVS tokens (must have approved this contract).
   *
   * Requirements:
   * - `amountToBurn` must not exceed minted CVS for `onBehalfOf`.
   * - `cvsFrom` must approve this contract to transfer CVS.
   *
   * Effects:
   * - Burns CVS from this contract's balance.
   * - Reduces `onBehalfOf`'s minted CVS balance.
   */
  function _burnCvs(
    uint256 amountToBurn,
    address onBehalfOf,
    address cvsFrom
  ) private {
    s_cvsMinted[onBehalfOf] -= amountToBurn;

    bool success = i_cvsToken.transferFrom(
      cvsFrom,
      address(this),
      amountToBurn
    );
    if (!success) {
      revert CVSEngine_TokenTransferFailed();
    }

    i_cvsToken.burn(amountToBurn);
  }

  //////////////////////////////
  // Private & Internal View & Pure Functions
  //////////////////////////////
  /**
   * @notice Computes the health factor of a user.
   * @param user The address of the user.
   * @return A scaled health factor (1e18 = safe; <1e18 = unhealthy).
   */
  function _healthFactor(address user) private view returns (uint256) {
    uint256 collateralInUsd = getAccountCollateralValueInUSD(user);
    uint256 debt = s_cvsMinted[user];

    if (debt == 0) return type(uint256).max;
    uint256 collateralAdjustedForThreshold = (collateralInUsd *
      LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

    return (collateralAdjustedForThreshold * PRECISION) / debt;
  }

  ////////////////////////////////////////////////////////////////////////////
  ////////////////////////////////////////////////////////////////////////////
  // External & Public View & Pure Functions
  ////////////////////////////////////////////////////////////////////////////
  ////////////////////////////////////////////////////////////////////////////
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
    (, int256 answer, , , ) = priceFeedAgg.staleCheckLatestRoundData();

    uint256 usdPrice = uint256(answer) * ADDITIONAL_FEED_PRECISION;
    collateralInUsd = (collateralAmount * usdPrice) / PRECISION;
  }

  /**
   * @notice Converts a given USD value into equivalent amount of collateral tokens.
   * @dev Assumes the collateral token has 18 decimals.
   * @param collateralAddress The ERC20 token to calculate against.
   * @param cvsAmount The dollar-equivalent amount (1 CVS = $1).
   * @return collateralAmount Amount of collateral tokens equivalent to cvsAmount in USD.
   */
  function convertUsdToCollateral(
    address collateralAddress,
    uint256 cvsAmount
  ) public view returns (uint256) {
    AggregatorV3Interface priceFeedAgg = AggregatorV3Interface(
      s_priceFeeds[collateralAddress]
    );
    (, int256 answer, , , ) = priceFeedAgg.staleCheckLatestRoundData();

    uint256 usdPrice = uint256(answer) * ADDITIONAL_FEED_PRECISION;

    return (cvsAmount * PRECISION) / usdPrice;
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
    amountInCvs = (amountInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
  }

  /**
   * @notice Returns the amount of CVS tokens minted by a user.
   * @param user The address of the user.
   * @return cvsMinted Amount of minted CVS.
   */
  function getCvsMinted(address user) public view returns (uint256 cvsMinted) {
    cvsMinted = s_cvsMinted[user];
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
   * @return "Healthy" or "Unhealthy" based on the health factor.
   */
  function isHealthy(address user) public view returns (string memory) {
    uint256 hf = _healthFactor(user);
    return hf < PRECISION ? "Unhealthy" : "Healthy";
  }

  function getPrecision() external pure returns (uint256) {
    return PRECISION;
  }

  function getAdditionalFeedPrecision() external pure returns (uint256) {
    return ADDITIONAL_FEED_PRECISION;
  }

  function getLiquidationThreshold() external pure returns (uint256) {
    return LIQUIDATION_THRESHOLD;
  }

  function getLiquidationBonus() external pure returns (uint256) {
    return LIQUIDATION_BONUS;
  }

  function getLiquidationPrecision() external pure returns (uint256) {
    return LIQUIDATION_PRECISION;
  }

  function getMinHealthFactor() external pure returns (uint256) {
    return MIN_HEALTH_FACTOR;
  }

  function getCollateralTokens() external view returns (address[] memory) {
    return s_collateralAddresses;
  }

  function getCvsToken() external view returns (address) {
    return address(i_cvsToken);
  }

  function getCollateralTokenPriceFeed(
    address token
  ) external view returns (address) {
    return s_priceFeeds[token];
  }

  /**
   * @notice Public wrapper around internal health factor logic.
   * @dev Health factor < 1e18 indicates liquidation risk.
   * @param user The user to evaluate.
   * @return The health factor of the user's position.
   */
  function getHealthFactor(address user) external view returns (uint256) {
    return _healthFactor(user);
  }

  function getMaxCvsToMint(address user) external view returns (uint256) {
    uint256 collateralInUsd = getAccountCollateralValueInUSD(user);
    uint256 debt = s_cvsMinted[user];

    uint256 collateralAdjustedForThreshold = (collateralInUsd *
      LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

    if (debt >= collateralAdjustedForThreshold) {
      return 0;
    }

    return collateralAdjustedForThreshold - debt;
  }

  function calculateHealthFactor(
    uint256 collateralInUsd,
    uint256 debt
  ) public pure returns (uint256) {
    if (debt == 0) return type(uint256).max;
    uint256 collateralAdjustedForThreshold = (collateralInUsd *
      LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

    return (collateralAdjustedForThreshold * PRECISION) / debt;
  }
}
