// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AsyncFiller } from "@async-swap/libraries/AsyncFiller.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

using AsyncFiller for AsyncOrder global;

/// @notice Represents an async order for a swap in the Uniswap V4 pool.
/// @param key The Uniswap V4 PoolKey that identifies the pool.
/// @param owner The owner of the order, who can claim the order.
/// @param zeroForOne Whether the order is for a swap from currency0 to currency1 (true) or currency1 to currency0
/// (false).
/// @param amountIn The amount of the order that is being filled.
/// @param sqrtPrice The square root price of the pool at the time of the order.
struct AsyncOrder {
  PoolKey key;
  address owner;
  bool zeroForOne;
  uint256 amountIn;
  uint160 sqrtPrice;
}
