// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DeployDecentralizedStableCoin} from "../../script/DeployDecentralizedStableCoin.s.sol";
import {CVSEngine} from "../../src/CVSEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract TestDecentralizedStableCoin is Test {
  DecentralizedStableCoin stableCoinToken;
  CVSEngine cvsEngine;
  HelperConfig helperConfig;
  address weth;
  address wbtc;
  address wethUsdPriceFeed;
  address wbtcUsdPriceFeed;
  address user = makeAddr("user");
  address liquidator = makeAddr("liquidator");
  uint256 constant CVS_TO_MINT = 100 * 1e18;
  uint256 public constant STARTING_USER_BALANCE = 10 ether;
  uint256 public constant STARTING_LIQUIDATOR_BALANCE = 200 ether;
  address[] public tokens;
  address[] public feeds;

  function setUp() public {
    DeployDecentralizedStableCoin deployer = new DeployDecentralizedStableCoin();
    (stableCoinToken, cvsEngine, helperConfig) = deployer.run();

    (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, ) = helperConfig
      .activeNetworkConfig();
    ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
  }

  modifier underCollateralized() {
    vm.startPrank(user);
    ERC20Mock(weth).approve(address(cvsEngine), STARTING_USER_BALANCE);
    cvsEngine.depositCollateralAndMintCvs(
      weth,
      STARTING_USER_BALANCE,
      CVS_TO_MINT
    );
    vm.stopPrank();
    int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
    MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
    _;
  }

  modifier overCollateralized() {
    vm.startPrank(user);
    ERC20Mock(weth).approve(address(cvsEngine), STARTING_USER_BALANCE);
    cvsEngine.depositCollateralAndMintCvs(
      weth,
      STARTING_USER_BALANCE,
      CVS_TO_MINT
    );
    vm.stopPrank();
    _;
  }

  function testConstructorInitializesCorrectly() public {
    tokens = [weth, wbtc];
    feeds = [wethUsdPriceFeed, wbtcUsdPriceFeed];

    CVSEngine engine = new CVSEngine(tokens, feeds, address(stableCoinToken));

    address priceFeedInEngine = engine.getCollateralTokenPriceFeed(weth);
    assertEq(priceFeedInEngine, wethUsdPriceFeed);
    assertEq(address(engine.getCvsToken()), address(stableCoinToken));
  }

  function testConstructorRevertsIfArrayLengthsMismatch() public {
    tokens = [weth];
    feeds = [wethUsdPriceFeed, wbtcUsdPriceFeed];

    vm.expectRevert(
      CVSEngine.CVSEngine_TokenAddressesMustMatchPriceFeeds.selector
    );
    new CVSEngine(tokens, feeds, address(stableCoinToken));
  }

  function testDepositCollateralAndMintCvs() public overCollateralized {
    uint256 userCvsBalance = cvsEngine.getCvsMinted(user);
    uint256 collateralDeposited = cvsEngine.getCollateralAmountByToken(
      user,
      weth
    );
    string memory isHealthy = cvsEngine.isHealthy(user);
    uint256 balanceOfUser = stableCoinToken.balanceOf(user);

    assertEq(collateralDeposited, STARTING_USER_BALANCE);
    assertEq(userCvsBalance, CVS_TO_MINT);
    assertEq(balanceOfUser, CVS_TO_MINT);
    assertEq(isHealthy, "Healthy");
  }

  function testCannotDepositZeroCollateral() public {
    vm.startPrank(user);

    ERC20Mock(weth).approve(address(cvsEngine), STARTING_USER_BALANCE);

    vm.expectRevert(CVSEngine.CVSEngine_AmountMustBeHigherThanZero.selector);
    cvsEngine.depositCollateralAndMintCvs(weth, 0, CVS_TO_MINT);

    vm.stopPrank();
  }

  function testCannotDepositUnsupportedCollateral() public {
    address fakeToken = address(0xdead);
    vm.startPrank(user);

    vm.expectRevert(CVSEngine.CVSEngine_CollateralTokenNotAllowed.selector);
    cvsEngine.depositCollateralAndMintCvs(
      fakeToken,
      STARTING_USER_BALANCE,
      CVS_TO_MINT
    );

    vm.stopPrank();
  }

  function testMintMoreThanAllowedFails() public {
    vm.startPrank(user);

    ERC20Mock(weth).approve(address(cvsEngine), STARTING_USER_BALANCE);

    // Try to mint a value too high relative to collateral
    uint256 excessiveMint = 100000 ether;

    vm.expectRevert(
      abi.encodeWithSelector(
        CVSEngine.CVSEngine_HealthFactorTooLow.selector,
        uint256(1e17), // simulated poor health factor (e.g. 0.1x)
        uint256(1e18) // PRECISION
      )
    );
    cvsEngine.depositCollateralAndMintCvs(
      weth,
      STARTING_USER_BALANCE,
      excessiveMint
    );

    vm.stopPrank();
  }

  function testGetAccountCollateralValueInUSDWorks() public overCollateralized {
    uint256 value = cvsEngine.getAccountCollateralValueInUSD(user);
    assertGt(value, 0);
  }

  function testHealthFactorCalculationIsAccurate() public overCollateralized {
    string memory healthStatus = cvsEngine.isHealthy(user);
    assertEq(healthStatus, "Healthy");
  }

  function testMultipleDepositsAndMints() public {
    vm.startPrank(user);

    ERC20Mock(weth).approve(address(cvsEngine), STARTING_USER_BALANCE);
    cvsEngine.depositCollateralAndMintCvs(
      weth,
      STARTING_USER_BALANCE / 2,
      CVS_TO_MINT / 2
    );
    cvsEngine.depositCollateralAndMintCvs(
      weth,
      STARTING_USER_BALANCE / 2,
      CVS_TO_MINT / 2
    );

    assertEq(
      cvsEngine.getCollateralAmountByToken(user, weth),
      STARTING_USER_BALANCE
    );
    assertEq(cvsEngine.getCvsMinted(user), CVS_TO_MINT);

    vm.stopPrank();
  }

  function testGetUsdValue() public view {
    uint256 ethAmount = 15e18;
    // 15e18 * 2000/ETH = 30,000e18
    uint256 expectedUsd = 30000e18;
    uint256 actualUsd = cvsEngine.getUsdValue(wethUsdPriceFeed, ethAmount);

    assertEq(actualUsd, expectedUsd);
  }

  function testRedeemCollateralWorksWhenHealthy() public overCollateralized {
    vm.startPrank(user);

    // Burn CVS to free up collateral
    stableCoinToken.approve(address(cvsEngine), CVS_TO_MINT);
    cvsEngine.burnCvs(CVS_TO_MINT);

    uint256 redeemAmount = 1 ether;
    cvsEngine.redeemCollateral(weth, redeemAmount);

    uint256 remainingCollateral = cvsEngine.getCollateralAmountByToken(
      user,
      weth
    );
    assertEq(remainingCollateral, STARTING_USER_BALANCE - redeemAmount);

    vm.stopPrank();
  }

  function testRedeemCollateralFailsIfUnhealthy() public overCollateralized {
    vm.startPrank(user);

    vm.expectRevert(
      abi.encodeWithSelector(
        CVSEngine.CVSEngine_HealthFactorTooLow.selector,
        uint256(0),
        uint256(1e18)
      )
    );
    cvsEngine.redeemCollateral(weth, STARTING_USER_BALANCE);

    vm.stopPrank();
  }

  function testRedeemCollateralForCvsWorks() public overCollateralized {
    vm.startPrank(user);

    stableCoinToken.approve(address(cvsEngine), CVS_TO_MINT);

    uint256 redeemAmount = 1 ether;
    uint256 cvsToMint = 2 * 1e18;
    cvsEngine.redeemCollateralForCvs(weth, redeemAmount, cvsToMint);

    uint256 remainingCollateral = cvsEngine.getCollateralAmountByToken(
      user,
      weth
    );
    uint256 remainingCvs = cvsEngine.getCvsMinted(user);
    assertEq(remainingCollateral, STARTING_USER_BALANCE - redeemAmount);
    assertEq(remainingCvs, CVS_TO_MINT - cvsToMint);

    vm.stopPrank();
  }

  function testBurnCvsReducesDebtAndMaintainsHealth()
    public
    overCollateralized
  {
    vm.startPrank(user);

    stableCoinToken.approve(address(cvsEngine), CVS_TO_MINT);
    cvsEngine.burnCvs(CVS_TO_MINT);

    uint256 debt = cvsEngine.getCvsMinted(user);
    assertEq(debt, 0);
    vm.stopPrank();
  }

  // Liquidation
  function testLiquidateAnUnderCollateralid() public underCollateralized {
    vm.startPrank(liquidator);
    ERC20Mock(weth).mint(liquidator, STARTING_LIQUIDATOR_BALANCE);
    ERC20Mock(weth).approve(address(cvsEngine), STARTING_LIQUIDATOR_BALANCE);

    cvsEngine.depositCollateralAndMintCvs(
      weth,
      STARTING_LIQUIDATOR_BALANCE,
      CVS_TO_MINT
    );
    stableCoinToken.approve(address(cvsEngine), CVS_TO_MINT);
    cvsEngine.liquidate(weth, user, CVS_TO_MINT); // We are covering their whole debt

    uint256 debt = cvsEngine.getCvsMinted(user);

    uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);

    uint256 expectedWeth = cvsEngine.convertUsdToCollateral(weth, CVS_TO_MINT) +
      ((cvsEngine.convertUsdToCollateral(weth, CVS_TO_MINT) *
        cvsEngine.getLiquidationBonus()) / cvsEngine.getLiquidationPrecision());

    assertEq(liquidatorWethBalance, expectedWeth);
    assertEq(debt, 0);

    vm.stopPrank();
  }

  function testCannotLiquidateHealthyUser() public overCollateralized {
    vm.startPrank(liquidator);
    ERC20Mock(weth).mint(liquidator, STARTING_LIQUIDATOR_BALANCE);
    ERC20Mock(weth).approve(address(cvsEngine), STARTING_LIQUIDATOR_BALANCE);

    cvsEngine.depositCollateralAndMintCvs(
      weth,
      STARTING_LIQUIDATOR_BALANCE,
      CVS_TO_MINT
    );
    stableCoinToken.approve(address(cvsEngine), CVS_TO_MINT);

    vm.expectRevert(CVSEngine.CVSEngine_CantLiquidateHealthyUser.selector);
    cvsEngine.liquidate(weth, user, CVS_TO_MINT);
    vm.stopPrank();
  }

  function testCannotLiquidateZeroDebt() public underCollateralized {
    vm.startPrank(liquidator);
    vm.expectRevert(CVSEngine.CVSEngine_AmountMustBeHigherThanZero.selector);
    cvsEngine.liquidate(weth, user, 0);
    vm.stopPrank();
  }

  function testHealthFactorImprovesAfterLiquidation()
    public
    underCollateralized
  {
    vm.startPrank(liquidator);
    ERC20Mock(weth).mint(liquidator, STARTING_LIQUIDATOR_BALANCE);
    ERC20Mock(weth).approve(address(cvsEngine), STARTING_LIQUIDATOR_BALANCE);

    cvsEngine.depositCollateralAndMintCvs(
      weth,
      STARTING_LIQUIDATOR_BALANCE,
      CVS_TO_MINT
    );
    stableCoinToken.approve(address(cvsEngine), CVS_TO_MINT);

    string memory before = cvsEngine.isHealthy(user);
    cvsEngine.liquidate(weth, user, CVS_TO_MINT);
    string memory afterHF = cvsEngine.isHealthy(user);

    assertEq(before, "Unhealthy");
    assertEq(afterHF, "Healthy");
    vm.stopPrank();
  }

  function testGetAccountCollateralValueInUSD() public overCollateralized {
    uint256 expected = cvsEngine.getUsdValue(
      wethUsdPriceFeed,
      STARTING_USER_BALANCE
    );
    uint256 actual = cvsEngine.getAccountCollateralValueInUSD(user);
    assertEq(actual, expected);
  }

  function testGetUsdValueWorksCorrectly() public view {
    uint256 wethAmount = 5 ether;
    uint256 expectedUsd = 5 * 2000 * 1e18; // 2000 price * 5 weth
    uint256 actual = cvsEngine.getUsdValue(wethUsdPriceFeed, wethAmount);
    assertEq(actual, expectedUsd);
  }

  function testConvertUsdToCollateralIsAccurate() public view {
    uint256 usdAmount = 10_000e18;
    uint256 expectedWeth = (usdAmount / 2_000e18) * cvsEngine.getPrecision(); // assuming 18 decimals
    uint256 actual = cvsEngine.convertUsdToCollateral(weth, usdAmount);
    assertEq(actual, expectedWeth);
  }

  function testConvertToCvsUsesLiquidationThreshold() public view {
    uint256 usd = 10_000e18;
    uint256 expected = (usd * cvsEngine.getLiquidationThreshold()) /
      cvsEngine.getLiquidationPrecision();
    uint256 actual = cvsEngine.convertToCvs(usd);
    assertEq(actual, expected);
  }

  function testGetCvsMintedReturnsCorrectAmount() public overCollateralized {
    uint256 minted = cvsEngine.getCvsMinted(user);
    assertEq(minted, CVS_TO_MINT);
  }

  function testGetCollateralAmountByTokenReturnsCorrectValue()
    public
    overCollateralized
  {
    uint256 amount = cvsEngine.getCollateralAmountByToken(user, weth);
    assertEq(amount, STARTING_USER_BALANCE);
  }

  function testIsHealthyReturnsCorrectStatus() public overCollateralized {
    string memory status = cvsEngine.isHealthy(user);
    assertEq(status, "Healthy");
  }

  function testIsHealthyReturnsUnhealthy() public underCollateralized {
    string memory status = cvsEngine.isHealthy(user);
    assertEq(status, "Unhealthy");
  }

  function testGetPrecisionValues() public view {
    assertEq(cvsEngine.getPrecision(), 1e18);
    assertEq(cvsEngine.getAdditionalFeedPrecision(), 1e10);
    assertEq(cvsEngine.getLiquidationThreshold(), 50); // e.g., 0.5
    assertEq(cvsEngine.getLiquidationBonus(), 10); // e.g., 10%
    assertEq(cvsEngine.getLiquidationPrecision(), 100);
    assertEq(cvsEngine.getMinHealthFactor(), 1e18); // must be at least 1
  }

  function testMintCvsSucceedsWhenHealthy() public overCollateralized {
    vm.startPrank(user);

    uint256 additionalMint = 10 * 1e18;
    stableCoinToken.approve(address(cvsEngine), additionalMint);
    cvsEngine.mintCvs(additionalMint);

    uint256 totalDebt = cvsEngine.getCvsMinted(user);
    assertEq(totalDebt, CVS_TO_MINT + additionalMint);

    uint256 balance = stableCoinToken.balanceOf(user);
    assertEq(balance, CVS_TO_MINT + additionalMint);

    vm.stopPrank();
  }

  function testMintCvsFailsWithZeroAmount() public {
    vm.startPrank(user);
    vm.expectRevert(CVSEngine.CVSEngine_AmountMustBeHigherThanZero.selector);
    cvsEngine.mintCvs(0);
    vm.stopPrank();
  }

  function testMintCvsFailsIfHealthFactorBreaks() public overCollateralized {
    vm.startPrank(user);

    // Set ETH price extremely low to simulate bad health factor
    int256 ethUsdUpdatedPrice = 1e8;
    MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

    vm.expectRevert(
      abi.encodeWithSelector(
        CVSEngine.CVSEngine_HealthFactorTooLow.selector,
        uint256(45454545454545454),
        uint256(cvsEngine.getPrecision())
      )
    );
    cvsEngine.mintCvs(10 * 1e18);

    vm.stopPrank();
  }
}
