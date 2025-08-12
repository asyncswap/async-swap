// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IAsyncSwapAMM } from "@async-swap/interfaces/IAsyncSwapAMM.sol";
import { IRouter } from "@async-swap/interfaces/IRouter.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { CurrencySettler } from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IERC20Minimal } from "v4-core/interfaces/external/IERC20Minimal.sol";
import { SafeCast } from "v4-core/libraries/SafeCast.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";

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
  function swap(AsyncOrder calldata order, bytes memory userData) external {
    address onBehalf = address(this);
    IAsyncSwapAMM.UserParams memory userParams = abi.decode(userData, (IAsyncSwapAMM.UserParams));
    require(userParams.executor == address(this), "Use router as your executor!");
    assembly ("memory-safe") {
      tstore(USER_LOCATION, caller())
      tstore(ASYNC_FILLER_LOCATION, onBehalf)
    }

    POOLMANAGER.unlock(abi.encode(SwapCallback(ActionType.Swap, order)));
  }

  /// @inheritdoc IRouter
  function fillOrder(AsyncOrder calldata order, bytes calldata) external {
    address onBehalf = address(this);
    assembly ("memory-safe") {
      tstore(USER_LOCATION, caller())
      /// force the async filler to be this router, otherwise could be a user parameter
      tstore(ASYNC_FILLER_LOCATION, onBehalf)
    }

    POOLMANAGER.unlock(abi.encode(SwapCallback(ActionType.FillOrder, order)));
  }

  /// Callback handler to unlock the PoolManager after a swap or fill order.
  /// @param data The callback data containing the action type and order information.
  /// @return Data to return back to the PoolManager after unlock.
  function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
    uint8 action;
    address user;
    address asyncFiller;

    assembly ("memory-safe") {
      tstore(ACTION_LOCATION, calldataload(0x44))
      action := tload(ACTION_LOCATION)
      user := tload(USER_LOCATION)
      asyncFiller := tload(ASYNC_FILLER_LOCATION)
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
      Currency currency = orderData.order.zeroForOne ? orderData.order.key.currency1 : orderData.order.key.currency0;
      assert(IERC20Minimal(Currency.unwrap(currency)).transferFrom(user, asyncFiller, orderData.order.amountIn));
      assert(IERC20Minimal(Currency.unwrap(currency)).approve(address(HOOK), orderData.order.amountIn));
      HOOK.executeOrder(orderData.order, abi.encode(asyncFiller));
    }

    return "";
  }

}
