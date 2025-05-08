// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";

contract DeployDecentralizedStableCoin is Script {
  DecentralizedStableCoin stableCoinToken;

  function run() public returns (DecentralizedStableCoin) {
    vm.startBroadcast();
    stableCoinToken = new DecentralizedStableCoin();
    vm.stopBroadcast();

    return stableCoinToken;
  }
}
