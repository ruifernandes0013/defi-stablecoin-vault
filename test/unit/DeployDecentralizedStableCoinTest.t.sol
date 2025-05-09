// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DeployDecentralizedStableCoin} from "../../script/DeployDecentralizedStableCoin.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract TestDecentralizedStableCoin is Test {
  DecentralizedStableCoin stableCoinToken;
  address owner;
  uint256 constant amount = 1 ether;
  uint256 constant amountToBurn = 0.5 ether;

  function setUp() public {
    DeployDecentralizedStableCoin deployer = new DeployDecentralizedStableCoin();
    (stableCoinToken, , ) = deployer.run();
    owner = stableCoinToken.owner();
  }

  // Test Mint
  function testCantMintWithNoAddress() public {
    vm.prank(owner);
    vm.expectRevert();
    stableCoinToken.mint(address(0), amount);
  }

  function testCantMintLessThanZero() public {
    vm.prank(owner);
    vm.expectRevert();
    stableCoinToken.mint(owner, 0);
  }

  function testMint() public {
    vm.prank(owner);
    stableCoinToken.mint(owner, amount);
    assertEq(stableCoinToken.balanceOf(owner), amount);
  }

  // Test Burn
  function testCantBurnLessThanZero() public {
    vm.prank(owner);
    stableCoinToken.mint(owner, amount);

    vm.prank(owner);
    vm.expectRevert();
    stableCoinToken.burn(0);
  }

  function testCantBurnMoreThanBalance() public {
    vm.prank(owner);
    stableCoinToken.mint(owner, amount);

    vm.prank(owner);
    vm.expectRevert();
    stableCoinToken.burn(amount + 1);
  }

  function testBurn() public {
    vm.prank(owner);
    stableCoinToken.mint(owner, amount);

    vm.prank(owner);
    stableCoinToken.burn(amountToBurn);

    assertEq(stableCoinToken.balanceOf(owner), amount - amountToBurn);
  }
}
