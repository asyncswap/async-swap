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
/// @author Asyncswap Labs
contract AsyncSwap is BaseHook, IAsyncSwapAMM {

  using SafeCast for *;
  using CurrencySettler for Currency;
  using PoolIdLibrary for PoolKey;
  using AsyncFiller for AsyncOrder;

  /// @notice Mapping to store async orders.
  mapping(PoolId poolId => AsyncFiller.State) public asyncOrders;
  /// Ordering algorithm
  IAlgorithm public immutable ALGORITHM;
  mapping(uint256 block => uint256 volatility) public kvolatility;

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
  error OrderExpired();

  /// Initializes the Async Swap Hook contract with the PoolManager address and sets an transaction ordering algorithm.
  /// @param poolManager The address of the PoolManager contract.
  constructor(IPoolManager poolManager) BaseHook(poolManager) {
    ALGORITHM = new CLVR(address(this));
  }

  /// @inheritdoc BaseHook
  function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
    require(key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, "Use dynamic fees flag");
    /// Set library state for the pool being initialized
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

  function asyncOrderAmount(PoolId poolId, address user, bool zeroForOne) external view returns (uint256 claimable) {
    AsyncFiller.State storage state = asyncOrders[poolId];
    return state.asyncOrderAmount[user][zeroForOne];
  }

  function isExecutor(PoolId poolId, address user, address executor) external view returns (bool) {
    AsyncFiller.State storage state = asyncOrders[poolId];
    return state.isExecutor[user][executor];
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
  function batch(
    AsyncOrder[] calldata buys,
    AsyncOrder[] calldata sells,
    bytes[] calldata buysData,
    bytes[] calldata sellsData
  ) external {
    uint256 buysLength = buys.length;
    uint256 sellsLength = sells.length;
    uint256 buysDataLength = buysData.length;
    uint256 sellsDataLength = sellsData.length;

    // check order length
    if (buysLength + sellsLength == 0) return;
    assert(buysDataLength == buysLength);
    assert(sellsDataLength == buysLength);

    // assert buys and sells are sorted
    assert(!buys[0].zeroForOne);
    for (uint256 i = 1; i < buys.length; i++) {
      assert(!buys[i].zeroForOne);
      assert(buys[i - 1].amountIn <= buys[i].amountIn);
    }
    assert(buys[0].zeroForOne);
    for (uint256 i = 1; i < buys.length; i++) {
      assert(buys[i].zeroForOne);
      assert(sells[i - 1].amountIn <= sells[i].amountIn);
    }

    AsyncOrder memory order;
    uint256 buyIndex;
    uint256 sellIndex;

    // pick first order
    if (buysLength == 0) {
      if (sellsLength > 0) {
        order = sells[0];
        sellIndex += 1;
        assert(order.zeroForOne);
      }
    }
    if (sellsLength == 0) {
      if (buysLength > 0) {
        order = buys[0];
        buyIndex += 1;
        assert(!order.zeroForOne);
      }
    }
    if (buysLength > 0 && sellsLength > 0) {
      if (buys[0].amountIn < sells[0].amountIn) {
        order = buys[0];
        buyIndex += 1;
      } else {
        order = sells[0];
        sellIndex += 1;
      }
    }

    int256 cumulative;
    // pick next order
    while (sellIndex <= sellsLength || buyIndex <= buysLength) {
      // process current order
      this.executeOrder(order, order.zeroForOne ? sellsData[sellIndex - 1] : buysData[buyIndex - 1]);

      if (order.zeroForOne) {
        cumulative += order.amountIn.toInt256();
        buyIndex += 1;
      } else {
        cumulative -= order.amountIn.toInt256();
        sellIndex += 1;
      }

      if (cumulative > 0) {
        if (sellIndex < sellsLength) {
          order = sells[sellIndex];
          sellIndex += 1;
        } else {
          if (buyIndex < buysLength) {
            order = buys[buyIndex];
            buyIndex += 1;
          } else {
            return;
          }
        }
      } else {
        if (buyIndex < buysLength) {
          order = buys[buyIndex];
          buyIndex += 1;
        } else {
          if (sellIndex < sellsLength) {
            order = sells[sellIndex];
            sellIndex += 1;
          } else {
            return;
          }
        }
      }
    }
  }

  function executeOrder(AsyncOrder memory order, bytes calldata fillerData) external {
    address owner = order.owner;
    uint256 amountIn = order.amountIn;
    bool zeroForOne = order.zeroForOne;
    Currency currency0 = order.key.currency0;
    Currency currency1 = order.key.currency1;
    PoolId poolId = order.key.toId();
    address filler = abi.decode(fillerData, (address));
    uint256 deadline = order.deadline;
    if (block.timestamp > deadline) revert OrderExpired();
    require(this.isExecutor(poolId, owner, msg.sender), "Caller is valid not executor");
    if (amountIn == 0) revert ZeroFillOrder();

    /// TODO: Document what this does
    uint256 amountToFill = uint256(amountIn);
    uint256 claimableAmount = asyncOrders[poolId].asyncOrderAmount[owner][zeroForOne];
    require(amountToFill <= claimableAmount, "Max fill order limit exceed");

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

    asyncOrders[poolId].asyncOrderAmount[owner][zeroForOne] -= amountToFill;
    /// we could also burn
    poolManager.transfer(filler, currencyTake.toId(), amountToFill);
    emit AsyncOrderFilled(poolId, owner, zeroForOne, amountToFill, deadline);

    /// @dev Take currencyFill from filler
    /// @dev Hook may charge filler a hook fee
    /// TODO: If fee emit HookFee event
    currencyFill.take(poolManager, owner, amountToFill, true);
    currencyFill.settle(poolManager, filler, amountToFill, false); // transfer
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
      revert("Hook only support ExactInput Amount");
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
    asyncOrders[poolId].isExecutor[hookData.user][hookData.executor] = true;
    emit AsyncSwapOrder(poolId, hookData.user, params.zeroForOne, finalTaken.toInt256());

    /// @dev Issue 1:1 claimableAmount - pool fee to user
    /// @dev Add amount taken to previous claimableAmount
    uint256 currClaimables = asyncOrders[poolId].asyncOrderAmount[hookData.user][params.zeroForOne];
    asyncOrders[poolId].asyncOrderAmount[hookData.user][params.zeroForOne] = currClaimables + finalTaken;

    /// @dev Hook event
    if (specified == key.currency0) {
      emit HookSwap(PoolId.unwrap(poolId), sender, amountTaken.toInt128(), 0, feeAmount.toUint128(), 0);
    } else {
      emit HookSwap(PoolId.unwrap(poolId), sender, 0, amountTaken.toInt128(), 0, feeAmount.toUint128());
    }

    BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(int128(-params.amountSpecified), 0);
    /// @dev return execution to PoolManager
    return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
  }

  error InvalidWithdrawal();
  error NotApprovedExecutor();

  function withdraw(PoolKey memory key, bool zeroForOne, uint256 amount, address user) external {
    PoolId poolId = key.toId();
    uint256 claim = asyncOrders[poolId].asyncOrderAmount[user][zeroForOne];

    // checks
    if (!asyncOrders[key.toId()].isExecutor[user][msg.sender]) revert NotApprovedExecutor();
    if (claim < amount) revert InvalidWithdrawal();
    assert(0 < amount && amount <= claim);
    // effect
    asyncOrders[poolId].asyncOrderAmount[user][zeroForOne] -= amount;
    // interaction
    Currency specified = zeroForOne ? key.currency0 : key.currency1;
    poolManager.burn(address(this), specified.toId(), amount);
    specified.take(poolManager, user, amount, false);
  }

}
