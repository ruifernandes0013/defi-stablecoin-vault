// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDecentralizedStableCoin} from "../../script/DeployDecentralizedStableCoin.s.sol";
import {CVSEngine} from "../../src/CVSEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
  DecentralizedStableCoin stableCoinToken;
  CVSEngine cvsEngine;
  HelperConfig helperConfig;
  Handler handler;
  address weth;
  address wbtc;
  address wethUsdPriceFeed;
  address wbtcUsdPriceFeed;

  function setUp() external {
    DeployDecentralizedStableCoin deployer = new DeployDecentralizedStableCoin();
    (stableCoinToken, cvsEngine, helperConfig) = deployer.run();

    (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, ) = helperConfig
      .activeNetworkConfig();

    handler = new Handler(stableCoinToken, cvsEngine);
    targetContract(address(handler));
  }

  function invariant_protocolMustHaveAlwaysMoreValueThanTotalSupply()
    public
    view
  {
    uint256 totalSupply = stableCoinToken.totalSupply();

    uint256 wethBalance = ERC20Mock(weth).balanceOf(address(cvsEngine));
    uint256 wbtcBalance = ERC20Mock(wbtc).balanceOf(address(cvsEngine));

    uint256 wethBalanceUsd = cvsEngine.getUsdValue(
      wethUsdPriceFeed,
      wethBalance
    );
    uint256 wbtcBalanceUsd = cvsEngine.getUsdValue(
      wbtcUsdPriceFeed,
      wbtcBalance
    );

    console.log("eth:", wethBalanceUsd);
    console.log("btc:", wbtcBalanceUsd);
    console.log("cvs:", totalSupply);
    console.log("index:", handler.index());

    assert(wethBalanceUsd + wbtcBalanceUsd >= totalSupply);
  }

  function invariant_gettersShouldNotRevert() public view {
    cvsEngine.getAccountCollateralValueInUSD(msg.sender);
    cvsEngine.getAdditionalFeedPrecision();
    // cvsEngine.getUsdValue();
    // cvsEngine.convertUsdTokCollateral(msg.sender);
    // cvsEngine.convertToCvs();
    cvsEngine.getCvsMinted(msg.sender);
    // cvsEngine.getCollateralAmountByToken();
    cvsEngine.isHealthy(msg.sender);
    cvsEngine.getPrecision();
    cvsEngine.getAdditionalFeedPrecision();
    cvsEngine.getLiquidationBonus();
    cvsEngine.getMinHealthFactor();
    cvsEngine.getLiquidationThreshold();
    cvsEngine.getCollateralTokens();
    cvsEngine.getCvsToken();
    // cvsEngine.getCollateralTokenPriceFeed();
    cvsEngine.getHealthFactor(msg.sender);
    cvsEngine.getMaxCvsToMint(msg.sender);
  }
}
