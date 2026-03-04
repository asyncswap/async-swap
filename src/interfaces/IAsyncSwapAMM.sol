// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAsyncSwapOrder } from "@async-swap/interfaces/IAsyncSwapOrder.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @title Async Swap AMM Interface
/// @author Async Labs
/// @notice This interface defines the functions for the Async CSMM (Constant Sum Market Maker) contract.
interface IAsyncSwapAMM is IAsyncSwapOrder {

  /// @notice Struct representing the user parameters for executing an async order.
  /// @param order The async order to be executed.
  /// @param userParams Additional parameter for the user, allowing user to specify an executor.
  struct UserParams {
    address user;
    address executor;
  }

  /// @notice Fill an async order in an Async Swap AMM.
  /// @param order The async order to be filled.
  /// @param fillerData ABI-encoded (address filler, uint256 amountOut).
  /// @return currencyFill The currency the filler must settle into the PoolManager.
  /// @return amountOut The amount of currencyFill to settle.
  function executeOrder(AsyncOrder calldata order, bytes calldata fillerData)
    external
    returns (Currency currencyFill, uint256 amountOut);

  function withdraw(PoolKey memory key, bool zeroForOne, uint256 amount, address user) external;

  function batch(
    AsyncOrder[] memory buys,
    AsyncOrder[] memory sells,
    bytes[] calldata buysData,
    bytes[] calldata sellsData
  ) external;

}
