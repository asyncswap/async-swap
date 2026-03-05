// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IAsyncSwapAMM } from "@async-swap/interfaces/IAsyncSwapAMM.sol";
import { IRouter } from "@async-swap/interfaces/IRouter.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { CurrencySettler } from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { SafeCast } from "v4-core/libraries/SafeCast.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @title Router Contract
/// @author Async Labs
/// @notice This contract implements the Router interface, allowing users to swap tokens and fill async orders through
/// the PoolManager and Async Swap hook.
contract Router is IRouter {

  using CurrencySettler for Currency;
  using CurrencyLibrary for Currency;
  using SafeCast for *;

  /// PoolManager contract to interact with the pools.
  IPoolManager immutable POOLMANAGER;
  /// Async Swap Hook contract to execute async orders.
  IAsyncSwapAMM immutable HOOK;

  /// keccak256("Router.ActionType") - 1
  bytes32 constant ACTION_LOCATION = 0xf3b150ebf41dad0872df6788629edb438733cb4a5c9ea779b1b1f3614faffc69;
  /// keccak256("Router.User") - 1
  bytes32 constant USER_LOCATION = 0x3dde20d9bf5cc25a9f487c6d6b54d3c19e3fa4738b91a7a509d4fc4180a72356;
  /// keccak256("Router.AsyncFiller") - 1
  bytes32 constant ASYNC_FILLER_LOCATION = 0xd972a937b59dc5cb8c692dd9f211e85afa8def4caee6e05b31db0f53e16d02e0;

  /// Initializes the Router contract with the PoolManager and Async CSMM hook.
  /// @param _poolManager The PoolManager contract that manages the pools.
  /// @param _hook The Async CSMM hook contract that executes async orders.
  constructor(IPoolManager _poolManager, IAsyncSwapAMM _hook) {
    POOLMANAGER = _poolManager;
    HOOK = _hook;
  }

  /// Only allow the PoolManager to call certain functions.
  modifier onlyPoolManager() {
    _checkCallerIsPoolManager();
    _;
  }

  function _checkCallerIsPoolManager() internal view {
    require(msg.sender == address(POOLMANAGER), "Caller is not PoolManager");
  }

  /// @inheritdoc IRouter
  function swap(AsyncOrder calldata order, bytes memory userData) external payable {
    address onBehalf = address(this);
    IAsyncSwapAMM.UserParams memory userParams = abi.decode(userData, (IAsyncSwapAMM.UserParams));
    require(userParams.executor == address(this), "Use router as your executor!");
    assembly ("memory-safe") {
      tstore(USER_LOCATION, caller())
      tstore(ASYNC_FILLER_LOCATION, onBehalf)
    }

    // Use minAmountOut as default for swap (not used in swap callback, but semantically meaningful)
    POOLMANAGER.unlock(
      abi.encode(SwapCallback({ action: ActionType.Swap, order: order, amountOut: order.minAmountOut }))
    );
  }

  /// @inheritdoc IRouter
  function fillOrder(AsyncOrder calldata order, bytes calldata userData) external payable {
    address onBehalf = address(this);
    // Decode the amount the filler is willing to provide
    uint256 amountOut = abi.decode(userData, (uint256));
    assembly ("memory-safe") {
      tstore(USER_LOCATION, caller())
      /// force the async filler to be this router, otherwise could be a user parameter
      tstore(ASYNC_FILLER_LOCATION, onBehalf)
    }

    POOLMANAGER.unlock(abi.encode(SwapCallback({ action: ActionType.FillOrder, order: order, amountOut: amountOut })));
  }

  function withdraw(PoolKey memory key, bool zeroForOne, uint256 amount) external {
    address onBehalf = address(this);
    assembly ("memory-safe") {
      tstore(USER_LOCATION, caller())
      tstore(ASYNC_FILLER_LOCATION, onBehalf)
    }

    POOLMANAGER.unlock(
      abi.encode(
        WithdrawCallback({
          action: ActionType.Withdrawal, key: key, zeroForOne: zeroForOne, amount: amount, user: msg.sender
        })
      )
    );
  }

  /// @inheritdoc IRouter
  function multicall(AsyncOrder[] calldata orders, bytes[] calldata ordersData)
    external
    payable
    returns (bool[] memory results)
  {
    address onBehalf = address(this);
    assembly ("memory-safe") {
      tstore(USER_LOCATION, caller())
      tstore(ASYNC_FILLER_LOCATION, onBehalf)
    }

    bytes memory returnData = POOLMANAGER.unlock(
      abi.encode(MulticallCallback({ action: ActionType.Multicall, orders: orders, ordersData: ordersData }))
    );

    results = abi.decode(returnData, (bool[]));
    return results;
  }

  /// Callback handler to unlock the PoolManager after a swap or fill order.
  /// @param data The callback data containing the action type and order information.
  /// @return Data to return back to the PoolManager after unlock.
  function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
    // Use assembly to get action for non-Multicall callbacks
    uint8 action;
    address user;
    address asyncFiller;

    assembly ("memory-safe") {
      tstore(ACTION_LOCATION, calldataload(0x44))
      action := tload(ACTION_LOCATION)
      user := tload(USER_LOCATION)
      asyncFiller := tload(ASYNC_FILLER_LOCATION)
    }

    // Check if this is a Multicall action (3)
    // For Multicall, the action is at a different offset due to array encoding
    // Try to detect Multicall by checking if assembly-extracted action >= 3
    // or if data suggests it's a Multicall structure
    if (action >= 3 || data.length > 1000) {
      // Multicall has large data with arrays
      // Try decoding as MulticallCallback
      try this._tryMulticall(data) returns (bool[] memory results) {
        return abi.encode(results);
      } catch {
        // Not a multicall, continue with normal flow
      }
    }

    /// @dev Handle Swap
    /// @dev process ActionType.Swap
    if (action == 0) {
      SwapCallback memory orderData = abi.decode(data, (SwapCallback));

      POOLMANAGER.swap(
        orderData.order.key,
        IPoolManager.SwapParams(
          orderData.order.zeroForOne, -orderData.order.amountIn.toInt256(), orderData.order.sqrtPrice
        ),
        abi.encode(user, asyncFiller)
      );
      Currency specified = orderData.order.zeroForOne ? orderData.order.key.currency0 : orderData.order.key.currency1;
      specified.settle(POOLMANAGER, user, orderData.order.amountIn, false); // transfer
    }

    /// @notice Handle Async Order Fill
    /// @dev FillingOrder
    if (action == 1) {
      SwapCallback memory orderData = abi.decode(data, (SwapCallback));
      // Execute order — hook validates, updates state, and transfers user's escrowed tokens to filler
      (Currency currencyFill, uint256 amountOut) =
        HOOK.executeOrder(orderData.order, abi.encode(user, orderData.amountOut));
      // Router settles filler's output tokens into the PoolManager first (creates +delta for router)
      currencyFill.settle(POOLMANAGER, user, amountOut, false);
      // Router transfers output tokens to order owner as ERC20 (-delta cancels +delta)
      currencyFill.take(POOLMANAGER, orderData.order.owner, amountOut, false);
    }

    /// @notice Handle withdrawals
    if (action == 2) {
      WithdrawCallback memory withdrawData = abi.decode(data, (WithdrawCallback));
      HOOK.withdraw(withdrawData.key, withdrawData.zeroForOne, withdrawData.amount, withdrawData.user);
    }

    return "";
  }

  /// @notice Internal function to try decoding and executing as multicall
  /// @dev This is external to enable try-catch, but should only be called by this contract
  function _tryMulticall(bytes calldata data) external returns (bool[] memory results) {
    require(msg.sender == address(this), "Only router can call");
    MulticallCallback memory multicallData = abi.decode(data, (MulticallCallback));

    // Verify it's actually a Multicall action
    require(multicallData.action == ActionType.Multicall, "Not a multicall");

    uint256 ordersLength = multicallData.orders.length;
    results = new bool[](ordersLength);

    for (uint256 i = 0; i < ordersLength; i++) {
      // Each order is attempted; decode filler address from ordersData for settlement
      (address filler,) = abi.decode(multicallData.ordersData[i], (address, uint256));
      try HOOK.executeOrder(multicallData.orders[i], multicallData.ordersData[i]) returns (
        Currency currencyFill, uint256 settleAmount
      ) {
        // Settle filler's output tokens into PoolManager (+delta for router)
        currencyFill.settle(POOLMANAGER, filler, settleAmount, false);
        // Transfer output tokens to order owner as ERC20 (-delta cancels +delta)
        currencyFill.take(POOLMANAGER, multicallData.orders[i].owner, settleAmount, false);
        results[i] = true;
      } catch {
        results[i] = false;
      }
    }

    return results;
  }

}
