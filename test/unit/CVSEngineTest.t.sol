// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DeployDecentralizedStableCoin} from "../../script/DeployDecentralizedStableCoin.s.sol";
import {CVSEngine} from "../../src/CVSEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract TestDecentralizedStableCoin is Test {
  DecentralizedStableCoin stableCoinToken;
  CVSEngine cvsEngine;
  HelperConfig helperConfig;
  address weth;
  address wbtc;
  address wethUsdPriceFeed;
  address user = makeAddr("user");
  uint256 constant CVS_TO_MINT = 100 * 1e18;
  uint256 public constant STARTING_USER_BALANCE = 10 ether;

  function setUp() public {
    DeployDecentralizedStableCoin deployer = new DeployDecentralizedStableCoin();
    (stableCoinToken, cvsEngine, helperConfig) = deployer.run();

    (wethUsdPriceFeed, , weth, wbtc, ) = helperConfig.activeNetworkConfig();
    ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
  }

  function testDepositCollateralAndMintCvs() public {
    vm.startPrank(user);

    ERC20Mock(weth).approve(address(cvsEngine), STARTING_USER_BALANCE);

    cvsEngine.depositCollateralAndMintCvs(
      weth,
      STARTING_USER_BALANCE,
      CVS_TO_MINT
    );

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
    vm.stopPrank();
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
        CVSEngine.CVSEngine_MaxAvailableTokensToMintExceed.selector,
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

  function testGetAccountCollateralValueInUSDWorks() public {
    vm.startPrank(user);

    ERC20Mock(weth).approve(address(cvsEngine), STARTING_USER_BALANCE);
    cvsEngine.depositCollateralAndMintCvs(
      weth,
      STARTING_USER_BALANCE,
      CVS_TO_MINT
    );

    uint256 value = cvsEngine.getAccountCollateralValueInUSD(user);
    assertGt(value, 0);

    vm.stopPrank();
  }

  function testHealthFactorCalculationIsAccurate() public {
    vm.startPrank(user);

    ERC20Mock(weth).approve(address(cvsEngine), STARTING_USER_BALANCE);
    cvsEngine.depositCollateralAndMintCvs(
      weth,
      STARTING_USER_BALANCE,
      CVS_TO_MINT
    );

    string memory healthStatus = cvsEngine.isHealthy(user);
    assertEq(healthStatus, "Healthy");

    vm.stopPrank();
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
}
