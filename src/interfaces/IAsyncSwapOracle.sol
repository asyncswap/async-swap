// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

interface IAsyncSwapOracle {
    /// @notice Return the reference sqrtPriceX96 and timestamp for a given pool.
    /// @param poolId The pool identifier
    /// @return sqrtPriceX96 Q96{sqrt(tok1/tok0)} The reference square-root price
    /// @return updatedAt {s} The timestamp when this price was last updated
    function getQuoteSqrtPriceX96(PoolId poolId) external view returns (uint160 sqrtPriceX96, uint256 updatedAt);
}
