// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import { CLVR } from "@async-swap/algorithms/clvr.sol";
import { IAlgorithm } from "@async-swap/interfaces/IAlgorithm.sol";
import { IAsyncSwapAMM } from "@async-swap/interfaces/IAsyncSwapAMM.sol";
import { AsyncFiller } from "@async-swap/libraries/AsyncFiller.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { CurrencySettler } from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";
import { SafeCast } from "v4-core/libraries/SafeCast.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { PoolIdLibrary, PoolKey } from "v4-core/types/PoolKey.sol";
import { BaseHook } from "v4-periphery/src/utils/BaseHook.sol";

/// @title Async Swap Contract
/// @author Async Labs
/// @notice Async swap AMM
contract AsyncSwap is BaseHook, IAsyncSwapAMM {

  using SafeCast for *;
  using CurrencySettler for Currency;
  using PoolIdLibrary for PoolKey;
  using AsyncFiller for AsyncOrder;

  /// @notice Mapping to store async orders.
  mapping(PoolId poolId => AsyncFiller.State) public asyncOrders;
  /// Ordering algortim
  IAlgorithm public immutable ALGORITHM;

  /// Event emitted when a swap is executed.
  /// @param id The poolId of the pool where the swap occurred.
  /// @param sender The address that initiated the swap.
  /// @param amount0 The amount of currency0 taken in the swap (negative for exact input).
  /// @param amount1 The amount of currency1 taken in the swap (negative for exact input).
  /// @param hookLPfeeAmount0 Fee amount taken for LP in currency0.
  /// @param hookLPfeeAmount1 Fee amount taken for LP in currency1.
  event HookSwap(
    bytes32 indexed id,
    address indexed sender,
    int128 amount0,
    int128 amount1,
    uint128 hookLPfeeAmount0,
    uint128 hookLPfeeAmount1
  );

  /// @notice Error thrown when liquidity is not supported in this hook.
  error UnsupportedLiquidity();

  /// Initializes the Async Swap Hook contract with the PoolManager address and sets an transaction ordering algorithm.
  /// @param poolManager The address of the PoolManager contract.
  constructor(IPoolManager poolManager) BaseHook(poolManager) {
    ALGORITHM = new CLVR(address(this));
  }

  /// @inheritdoc BaseHook
  function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
    require(key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, "Dude use dynamic fees flag");
    /// set algorithm for the pool being initialized
    asyncOrders[key.toId()].algorithm = ALGORITHM;
    asyncOrders[key.toId()].poolManager = poolManager;
    return this.beforeInitialize.selector;
  }

  /// @inheritdoc BaseHook
  function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
      beforeInitialize: true,
      afterInitialize: false,
      beforeAddLiquidity: true, // override liquidity functionality
      afterAddLiquidity: false,
      beforeRemoveLiquidity: false,
      afterRemoveLiquidity: false,
      beforeSwap: true, // override how swaps are done async swap
      afterSwap: false,
      beforeDonate: false,
      afterDonate: false,
      beforeSwapReturnDelta: true, // need must for async
      afterSwapReturnDelta: false,
      afterAddLiquidityReturnDelta: false,
      afterRemoveLiquidityReturnDelta: false
    });
  }

  /// @inheritdoc BaseHook
  function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
    internal
    pure
    override
    returns (bytes4)
  {
    revert UnsupportedLiquidity();
  }

  function asyncOrder(PoolId poolId, address user, bool zeroForOne) external view returns (uint256 claimable) {
    AsyncFiller.State storage state = asyncOrders[poolId];
    return state.asyncOrders[user][zeroForOne];
  }

  function isExecutor(PoolId poolId, address user, address executor) external view returns (bool) {
    AsyncFiller.State storage state = asyncOrders[poolId];
    return state.setExecutor[user][executor];
  }

  function calculateHookFee(uint256) public pure returns (uint256) {
    return 0;
  }

  function calculatePoolFee(uint24, uint256) public pure returns (uint256) {
    /// TODO: check for dynamic fees
    /// TODO: Read from the state slot
    return 0;
  }

  /// @inheritdoc IAsyncSwapAMM
  function executeOrders(AsyncOrder[] calldata orders, bytes calldata userParams) external {
    for (uint8 i = 0; i < orders.length; i++) {
      AsyncOrder calldata order = orders[i];
      // Use transaction ordering algorithm to ensure correct execution order
      asyncOrders[order.key.toId()].algorithm.orderingRule(order.zeroForOne, uint256(order.amountIn));
      this.executeOrder(order, userParams);
    }
  }

  /// @inheritdoc IAsyncSwapAMM
  function executeOrder(AsyncOrder calldata order, bytes calldata) external {
    address owner = order.owner;
    uint256 amountIn = order.amountIn;
    bool zeroForOne = order.zeroForOne;
    Currency currency0 = order.key.currency0;
    Currency currency1 = order.key.currency1;
    PoolId poolId = order.key.toId();

    if (amountIn == 0) revert ZeroFillOrder();

    /// TODO: Document what this does
    uint256 amountToFill = uint256(amountIn);
    uint256 claimableAmount = asyncOrders[poolId].asyncOrders[owner][zeroForOne];
    require(amountToFill <= claimableAmount, "Max fill order limit exceed");
    AsyncFiller.State storage state = asyncOrders[poolId];
    require(order.isExecutor(state, msg.sender), "Caller is valid not excutor");

    /// @dev Transfer currency of async order to user
    Currency currencyTake;
    Currency currencyFill;
    if (order.zeroForOne) {
      currencyTake = currency0;
      currencyFill = currency1;
    } else {
      currencyTake = currency1;
      currencyFill = currency0;
    }

    asyncOrders[poolId].asyncOrders[owner][zeroForOne] -= amountToFill;
    /// TODO: check if this is needed, we could just burn
    poolManager.transfer(owner, currencyTake.toId(), amountToFill);
    emit AsyncOrderFilled(poolId, owner, zeroForOne, amountToFill);

    /// @dev Take currencyFill from filler
    /// @dev Hook may charge filler a hook fee
    /// TODO: If fee emit HookFee event
    currencyFill.take(poolManager, address(this), amountToFill, true);
    currencyFill.settle(poolManager, msg.sender, amountToFill, false); // transfer
  }

  /// @inheritdoc BaseHook
  function _beforeSwap(
    address sender,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    bytes calldata hookParams
  ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
    /// @dev Async swaps only work for exact-input swaps
    if (params.amountSpecified > 0) {
      revert("Hook only support ExectInput Amount");
    }

    PoolId poolId = key.toId();
    uint256 amountTaken = uint256(-params.amountSpecified);
    UserParams memory hookData = abi.decode(hookParams, (UserParams));

    /// @dev Specify the input token
    Currency specified = params.zeroForOne ? key.currency0 : key.currency1;

    /// @dev create hook debt
    specified.take(poolManager, address(this), amountTaken, true);
    /// @dev Take pool fee for LP
    uint256 feeAmount = calculatePoolFee(key.fee, amountTaken);
    uint256 finalTaken = amountTaken - feeAmount;
    asyncOrders[poolId].setExecutor[hookData.user][hookData.executor] = true;
    emit AsyncSwapOrder(poolId, hookData.user, params.zeroForOne, finalTaken.toInt256());

    /// @dev Issue 1:1 claimableAmount - pool fee to user
    /// @dev Add amount taken to previous claimableAmount
    uint256 currClaimables = asyncOrders[poolId].asyncOrders[hookData.user][params.zeroForOne];
    asyncOrders[poolId].asyncOrders[hookData.user][params.zeroForOne] = currClaimables + finalTaken;

    /// @dev Hook event
    /// @reference
    /// https://github.com/OpenZeppelin/uniswap-hooks/blob/19fa03bdacd780a3e44f7c3707d6881e364d9596/src/base/BaseAsyncSwap.sol#L75
    if (specified == key.currency0) {
      emit HookSwap(PoolId.unwrap(poolId), sender, amountTaken.toInt128(), 0, feeAmount.toUint128(), 0);
    } else {
      emit HookSwap(PoolId.unwrap(poolId), sender, 0, amountTaken.toInt128(), 0, feeAmount.toUint128());
    }

    BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(int128(-params.amountSpecified), 0);
    /// @dev return execution to PoolManager
    return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
  }

}
