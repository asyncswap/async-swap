// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAsyncSwapOrder } from "@async-swap/interfaces/IAsyncSwapOrder.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";

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
  /// @param userParams Additional data for the user.
  function executeOrder(AsyncOrder calldata order, bytes calldata userParams) external;

  /// Fills async orders in batching mode, allowing multiple orders to be executed in a single transaction.
  /// @param orders An array of async orders to be executed.
  /// @param userParams Additional data for the user, allowing user to specify an executor.
  function executeOrders(AsyncOrder[] calldata orders, bytes calldata userParams) external;

}
