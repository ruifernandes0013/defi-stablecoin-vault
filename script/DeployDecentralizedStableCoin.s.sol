// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {CVSEngine} from "../src/CVSEngine.sol";
import {HelperConfig} from "../script/HelperConfig.sol";

contract DeployDecentralizedStableCoin is Script {
  address[] public tokenAddresses;
  address[] public priceFeedAddresses;

  function run()
    public
    returns (DecentralizedStableCoin, CVSEngine, HelperConfig)
  {
    HelperConfig helperConfig = new HelperConfig();
    (
      address wethUsdPriceFeed,
      address wbtcUsdPriceFeed,
      address weth,
      address wbtc,
      uint256 deployerKey
    ) = helperConfig.activeNetworkConfig();
    tokenAddresses = [weth, wbtc];
    priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

    vm.startBroadcast(deployerKey);
    DecentralizedStableCoin stableCoinToken = new DecentralizedStableCoin();
    address cvsTokenAddress = address(stableCoinToken);

    CVSEngine cvsEngine = new CVSEngine(
      tokenAddresses,
      priceFeedAddresses,
      cvsTokenAddress
    );
    stableCoinToken.transferOwnership(address(cvsEngine));
    vm.stopBroadcast();

    return (stableCoinToken, cvsEngine, helperConfig);
  }
}
