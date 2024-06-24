// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Patrick Collins
 * @notice It checks Chainlink Oracle for Stale data.
 * It reverts if price is stale and renders dsceengine unusable by design
 * DSEEngine is to freeze if price becoes stale
 */

library OracleLib {
    error OracleLib__StalePrice();
    uint256 private constant TIMEOUT = 3 hours; // 3 * 60 * 60 = 10000 seconds

    function staleCheckLatestRoundData(
        AggregatorV3Interface priceFeed
    ) public view returns (uint80, int256, uint256, uint256, uint80) {
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInround
        ) = priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) {
            revert OracleLib__StalePrice();
        }

        return (roundId, answer, startedAt, updatedAt, answeredInround);
    }
}
