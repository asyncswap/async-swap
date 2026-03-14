// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

interface IAsyncSwapOracle {
    /// @notice Return the reference sqrtPriceX96 and timestamp for a given pool.
    function getQuoteSqrtPriceX96(PoolId poolId) external view returns (uint160 sqrtPriceX96, uint256 updatedAt);
}
