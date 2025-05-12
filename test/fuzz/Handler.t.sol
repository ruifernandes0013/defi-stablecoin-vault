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

contract Handler is StdInvariant, Test {
  DecentralizedStableCoin stableCoinToken;
  CVSEngine cvsEngine;
  ERC20Mock wETH;
  ERC20Mock wBTC;
  uint256 constant MAX_DEPOSIT_AMOUNT = type(uint96).max;
  address[] users;
  uint256 public index;
  mapping(address collateral => address priceFeed) private collateralPriceFeeds;
  MockV3Aggregator wETHPriceFeed;
  MockV3Aggregator wBTCPriceFeed;

  constructor(DecentralizedStableCoin _stableCoinToken, CVSEngine _cvsEngine) {
    stableCoinToken = _stableCoinToken;
    cvsEngine = _cvsEngine;

    address[] memory tokens = cvsEngine.getCollateralTokens();
    address eth = address(tokens[0]);
    address btc = address(tokens[1]);
    wETH = ERC20Mock(eth);
    wBTC = ERC20Mock(btc);
    collateralPriceFeeds[eth] = cvsEngine.getCollateralTokenPriceFeed(eth);
    collateralPriceFeeds[btc] = cvsEngine.getCollateralTokenPriceFeed(btc);
    wETHPriceFeed = MockV3Aggregator(
      cvsEngine.getCollateralTokenPriceFeed(eth)
    );
    wBTCPriceFeed = MockV3Aggregator(
      cvsEngine.getCollateralTokenPriceFeed(btc)
    );
  }

  function mintCvs(uint256 amountToMint, uint256 addressIndex) public {
    if (addressIndex <= 0 || users.length <= 0) {
      return;
    }
    address sender = users[addressIndex % users.length];
    uint256 maxToMint = cvsEngine.getMaxCvsToMint(sender);
    if (maxToMint <= 0) {
      return;
    }
    index++;
    amountToMint = bound(amountToMint, 0, maxToMint);
    if (amountToMint == 0) {
      return;
    }
    vm.startPrank(sender);
    cvsEngine.mintCvs(amountToMint);
    vm.stopPrank();
  }

  function depositCollateral(uint256 cIndex, uint256 cAmount) public {
    ERC20Mock cAddress = _getCollateralSeed(cIndex);
    cAmount = bound(cAmount, 1, MAX_DEPOSIT_AMOUNT);

    cAddress.mint(msg.sender, cAmount);

    vm.startPrank(msg.sender);
    cAddress.approve(address(cvsEngine), cAmount);
    cvsEngine.depositCollateral(address(cAddress), cAmount);
    vm.stopPrank();
    users.push(msg.sender);
  }

  function redeemCollateral(uint256 cIndex, uint256 cAmount) public {
    ERC20Mock cAddress = _getCollateralSeed(cIndex);

    uint256 MAX_USER_COLLATERAL = cvsEngine.getCollateralAmountByToken(
      msg.sender,
      address(cAddress)
    );
    if (MAX_USER_COLLATERAL <= 0) {
      return;
    }
    cAmount = bound(cAmount, 0, MAX_USER_COLLATERAL);
    if (cAmount <= 0) {
      return;
    }
    vm.startPrank(msg.sender);
    uint256 cAmountUsd = cvsEngine.getUsdValue(
      collateralPriceFeeds[address(cAddress)],
      cAmount
    );
    uint256 debt = cvsEngine.getCvsMinted(msg.sender);
    uint256 userCollateralUsd = cvsEngine.getAccountCollateralValueInUSD(
      msg.sender
    );
    uint256 healthFactor = cvsEngine.calculateHealthFactor(
      userCollateralUsd - cAmountUsd,
      debt
    );
    if (healthFactor < cvsEngine.getMinHealthFactor()) {
      return;
    }
    cvsEngine.redeemCollateral(address(cAddress), cAmount);
    vm.stopPrank();
  }

  // function updateCollateralPrice(uint96 newPrice) public {
  //   int256 price = int256(uint256(newPrice));
  //   wETHPriceFeed.updateAnswer(price);
  // }

  function _getCollateralSeed(uint256 cIndex) private view returns (ERC20Mock) {
    if (cIndex % 2 == 0) {
      return wETH;
    }
    return wBTC;
  }
}
