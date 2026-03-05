// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @title Router Interface
/// @author Async Labs
/// @notice This interface defines the functions for the Router contract, which allows users to swap tokens and fill
/// orders using async orders.
interface IRouter {

  /// Enum representing the action type for the swap callback.
  /// 1. Swap - If the action is a swap, this will specify the async swap order intent.
  /// 2. FillOrder - If the action is a fill order, this will specify fill order intent.
  /// 3. Withdrawal - If the action is a withdrawal, this will specify withdrawal intent.
  /// 4. Multicall - If the action is a multicall, this will specify multicall intent.
  enum ActionType {
    Swap,
    FillOrder,
    Withdrawal,
    Multicall
  }

  /// Callback structure for the swap function.
  /// @param action The action type, either Swap or FillOrder.
  /// @param order The async order that is in context for the swap or fill operation.
  /// @param amountOut The amount the filler is offering (only used for FillOrder action).
  struct SwapCallback {
    ActionType action;
    AsyncOrder order;
    uint256 amountOut;
  }

  struct WithdrawCallback {
    ActionType action;
    PoolKey key;
    bool zeroForOne;
    uint256 amount;
    address user;
  }

  struct MulticallCallback {
    ActionType action;
    AsyncOrder[] orders;
    bytes[] ordersData;
  }

  /// Swaps tokens using an async order.
  /// @param order The async order to be placed.
  /// @param userData Additional data for the user, allowing user to specify an executor.
  function swap(AsyncOrder calldata order, bytes calldata userData) external payable;

  /// Fills an async order.
  /// @param order The async order to be filled.
  /// @param userData Additional data for the user, allowing user to specify an executor.
  function fillOrder(AsyncOrder calldata order, bytes calldata userData) external payable;

  function withdraw(PoolKey memory key, bool zeroForOne, uint256 amount) external;

  /// Execute multiple orders with graceful failure handling.
  /// @dev Individual order failures don't revert the entire transaction.
  /// @param orders Array of orders to execute.
  /// @param ordersData Array of filler data corresponding to each order.
  /// @return results Array of booleans indicating success/failure for each order.
  function multicall(AsyncOrder[] calldata orders, bytes[] calldata ordersData)
    external
    payable
    returns (bool[] memory results);

}
