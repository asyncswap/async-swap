// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAlgorithm } from "@async-swap/interfaces/IAlgorithm.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { CurrencySettler } from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { PoolIdLibrary, PoolKey } from "v4-core/types/PoolKey.sol";

/// @title AsyncFiller library
/// @author Async Labs
/// @notice This library provides functionality for filling async swap orders in the Uniswap V4 pool.
library AsyncFiller {

  using CurrencySettler for Currency;
  using PoolIdLibrary for PoolKey;
  using AsyncFiller for State;

  /// Represents the state of the AsyncFiller library storage for async orders and executors.
  /// @param poolManager The PoolManager contract that manages the pools.
  /// @param asyncOrders A mapping of poolId to user orders, where each order can be claimed by the user.
  /// @param setExecutor A mapping of user addresses to their executors, allowing users to specify who can fill their
  /// async orders.
  struct State {
    IPoolManager poolManager;
    IAlgorithm algorithm;
    mapping(address user => mapping(bool zeroForOne => uint256 claimable)) asyncOrderAmount;
    mapping(address owner => mapping(address executor => bool)) isExecutor;
  }

  /// @notice Emitted when an async order is filled.
  /// @param poolId The poolId of the pool where the order is placed.
  /// @param owner The owner of the order, who can claim the order.
  /// @param zeroForOne Whether the order is for a swap from currency0 to currency1 (true) or currency1 to currency0
  /// (false).
  /// @param amount The amount of the order.
  event AsyncOrderFilled(PoolId poolId, address owner, bool zeroForOne, uint256 amount);

  /// @notice Error thrown when an order is invalid.
  error InvalidOrder();
  /// @notice Error thrown when an order is of zero amount.
  error ZeroFillOrder();

  /// @notice Checks if the given executor is valid for the async order.
  /// @param order The async order to be filled.
  /// @param self The storage slot that controls the state of orders.
  /// @param executor The address of the executor to be checked.
  /// @return isExecutor True if the executor is valid for the async order, false otherwise.
  function isExecutor(AsyncOrder calldata order, State storage self, address executor) internal view returns (bool) {
    return self.isExecutor[order.owner][executor];
  }

  /// Fills async orders in batching mode, allowing multiple orders to be executed in a single transaction.
  /// @param orders An array of async orders to be executed.
  /// @param userParams Additional data for the user, allowing user to specify an executor.
  function executeOrder(AsyncOrder[] calldata orders, State storage self, bytes calldata userParams) external {
    for (uint8 i = 0; i < orders.length; i++) {
      AsyncOrder calldata order = orders[i];
      // execute order
      self.algorithm.orderingRule(order.zeroForOne, order.amountIn);
      _execute(order, self, userParams);
    }
  }

  /// @notice Fill an async order in an Async Swap AMM.
  /// @param order The async order to be filled.
  /// @param self The state of the AsyncFiller library, containing async orders and executors.
  function _execute(AsyncOrder calldata order, State storage self, bytes calldata) internal {
    if (order.amountIn == 0) revert ZeroFillOrder();

    PoolId poolId = order.key.toId();
    uint256 amountToFill = uint256(order.amountIn);
    uint256 claimableAmount = self.asyncOrderAmount[order.owner][order.zeroForOne];
    require(amountToFill <= claimableAmount, "Max fill order limit exceed");
    require(isExecutor(order, self, msg.sender), "Caller is valid not excutor");

    /// @dev Transfer currency of async order to user
    Currency currencyTake;
    Currency currencyFill;
    if (order.zeroForOne) {
      currencyTake = order.key.currency0;
      currencyFill = order.key.currency1;
    } else {
      currencyTake = order.key.currency1;
      currencyFill = order.key.currency0;
    }

    self.asyncOrderAmount[order.owner][order.zeroForOne] -= amountToFill;
    self.poolManager.transfer(order.owner, currencyTake.toId(), amountToFill);
    emit AsyncOrderFilled(poolId, order.owner, order.zeroForOne, amountToFill);

    /// @dev Take currencyFill from filler
    /// @dev Hook may charge filler a hook fee
    /// TODO: If fee emit HookFee event
    currencyFill.take(self.poolManager, address(this), amountToFill, true);
    currencyFill.settle(self.poolManager, msg.sender, amountToFill, false); // transfer
  }

}
