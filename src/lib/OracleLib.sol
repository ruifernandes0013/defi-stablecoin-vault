// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 *  @author Rui Fernandes
 * @notice This is the library that will be used to check if
 *         the ChainLink Oracle is stale or not.
 * We want to make sure that ig the price is stale the function
 *         will be reverted and the CVSEngine will be unusable.
 *
 * The protocol must freeze when prices become stale.
 */
library OracleLib {
  error OracleLib_StaledPrice();
  uint256 private constant TIMEOUT = 3 hours;

  function staleCheckLatestRoundData(
    AggregatorV3Interface priceFeed
  ) public view returns (uint80, int256, uint256, uint256, uint80) {
    (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) = priceFeed.latestRoundData();

    uint256 secondsSince = block.timestamp - updatedAt;
    if (secondsSince > TIMEOUT) {
      revert OracleLib_StaledPrice();
    }

    return (roundId, answer, startedAt, updatedAt, answeredInRound);
  }
}
