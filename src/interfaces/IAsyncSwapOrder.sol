// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PoolId } from "v4-core/types/PoolId.sol";

/// @title Async Swap Interface
/// @author Async Labs
/// @notice This interface defines the functions for the Async Swap orders.
interface IAsyncSwapOrder {

  /// @notice Emitted when an async order is filled.
  /// @param poolId The poolId of the pool where the order is placed.
  /// @param owner The owner of the order, who can claim the order.
  /// @param zeroForOne Whether the order is for a swap from currency0 to currency1 (true) or currency1 to currency0
  /// (false).
  /// @param amount The amount of the order.
  event AsyncOrderFilled(PoolId poolId, address owner, bool zeroForOne, uint256 amount);

  /// @notice Emitted when an async swap order is created.
  /// @param poolId The poolId of the pool where the order is placed.
  /// @param owner The owner of the order, who can claim the order.
  /// @param zeroForOne Whether the order is for a swap from currency0 to currency1 (true) or currency1 to currency0
  /// (false).
  /// @param amountIn The amount of the order that is being filled.
  event AsyncSwapOrder(PoolId poolId, address owner, bool indexed zeroForOne, int256 indexed amountIn);

  /// @notice Error thrown when an order is invalid.
  error InvalidOrder();
  /// @notice Error thrown when an order is of zero amount.
  error ZeroFillOrder();

  /// @notice Returns the claimable amount for an async order.
  /// @param poolId The poolId of the pool where the order is placed.
  /// @param user The user who placed the order.
  /// @param zeroForOne Whether the order is for a swap from currency0 to currency1 (true) or currency1 to currency0
  /// (false).
  /// @return claimable The amount that can be claimed by the user.
  function asyncOrder(PoolId poolId, address user, bool zeroForOne) external view returns (uint256 claimable);

  /// @notice Checks if the given executor is valid for the async order.
  /// @param poolId The poolId the executor is interacting with.
  /// @param owner The async order owner be checked against.
  /// @param executor The address of the executor to be checked.
  /// @return isExecutor True if the executor is valid for the async order, false otherwise.
  function isExecutor(PoolId poolId, address owner, address executor) external returns (bool);

}
