// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";

/// @title Router Interface
/// @author Async Labs
/// @notice This interface defines the functions for the Router contract, which allows users to swap tokens and fill
/// orders using async orders.
interface IRouter {

  /// Enum representing the action type for the swap callback.
  /// 1. Swap - If the action is a swap, this will specify the async swap order intent.
  /// 2. FillOrder - If the action is a fill order, this will specify fill order intent.
  enum ActionType {
    Swap,
    FillOrder
  }

  /// Callback structure for the swap function.
  /// @param action The action type, either Swap or FillOrder.
  /// @param order The async order that is in context for the swap or fill operation.
  struct SwapCallback {
    ActionType action;
    AsyncOrder order;
  }

  /// Swaps tokens using an async order.
  /// @param order The async order to be placed.
  /// @param userData Additional data for the user, allowing user to specify an executor.
  function swap(AsyncOrder calldata order, bytes calldata userData) external;

  /// Fills an async order.
  /// @param order The async order to be filled.
  /// @param userData Additional data for the user, allowing user to specify an executor.
  function fillOrder(AsyncOrder calldata order, bytes calldata userData) external;

}
