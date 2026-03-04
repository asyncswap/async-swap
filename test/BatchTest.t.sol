// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { AsyncSwap } from "@async-swap/AsyncSwap.sol";
import { IAsyncSwapOrder } from "@async-swap/interfaces/IAsyncSwapOrder.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";

/// @title Batch ordering edge-case tests
/// @notice Tests the validation logic inside AsyncSwap.batch() that fires before any pool interaction.
contract BatchTest is SetupHook {

  address batchUser = makeAddr("batchUser");

  function setUp() public override {
    super.setUp();
    topUp(batchUser, 10 ether);
  }

  // ─── helpers ─────────────────────────────────────────────────────────────

  function _buy(uint256 amt) internal view returns (AsyncOrder memory) {
    return AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: batchUser,
      zeroForOne: false, // buy = zeroForOne=false
      amountIn: amt,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });
  }

  function _sell(uint256 amt) internal view returns (AsyncOrder memory) {
    return AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: batchUser,
      zeroForOne: true, // sell = zeroForOne=true
      amountIn: amt,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });
  }

  // ─── empty batch ─────────────────────────────────────────────────────────

  /// @notice An empty batch (no buys, no sells) is a no-op and must not revert.
  function testBatch_EmptyBatch() public {
    AsyncOrder[] memory buys = new AsyncOrder[](0);
    AsyncOrder[] memory sells = new AsyncOrder[](0);
    bytes[] memory buysData = new bytes[](0);
    bytes[] memory sellsData = new bytes[](0);

    // should return without reverting
    hook.batch(buys, sells, buysData, sellsData);
  }

  // ─── direction validation ─────────────────────────────────────────────────

  /// @notice A buy order with zeroForOne=true placed in the buys array must revert.
  function testBatch_RevertsWrongDirectionInBuys() public {
    // buys must have zeroForOne=false; passing a sell-direction order in buys is invalid
    AsyncOrder memory wrongBuy = _sell(100); // zeroForOne=true — wrong for buys array

    AsyncOrder[] memory buys = new AsyncOrder[](1);
    buys[0] = wrongBuy;
    AsyncOrder[] memory sells = new AsyncOrder[](0);
    bytes[] memory buysData = new bytes[](1);
    buysData[0] = abi.encode(address(this), uint256(100));
    bytes[] memory sellsData = new bytes[](0);

    vm.expectRevert(AsyncSwap.InvalidOrderDirection.selector);
    hook.batch(buys, sells, buysData, sellsData);
  }

  /// @notice A sell order with zeroForOne=false placed in the sells array must revert.
  function testBatch_RevertsWrongDirectionInSells() public {
    // sells must have zeroForOne=true; passing a buy-direction order in sells is invalid
    AsyncOrder memory wrongSell = _buy(100); // zeroForOne=false — wrong for sells array

    AsyncOrder[] memory buys = new AsyncOrder[](0);
    AsyncOrder[] memory sells = new AsyncOrder[](1);
    sells[0] = wrongSell;
    bytes[] memory buysData = new bytes[](0);
    bytes[] memory sellsData = new bytes[](1);
    sellsData[0] = abi.encode(address(this), uint256(100));

    vm.expectRevert(AsyncSwap.InvalidOrderDirection.selector);
    hook.batch(buys, sells, buysData, sellsData);
  }

  // ─── sort validation ──────────────────────────────────────────────────────

  /// @notice Buys array not sorted ascending by amountIn must revert.
  function testBatch_RevertsUnsortedBuys() public {
    AsyncOrder[] memory buys = new AsyncOrder[](2);
    buys[0] = _buy(500);
    buys[1] = _buy(200); // 500 > 200 — not sorted ascending

    AsyncOrder[] memory sells = new AsyncOrder[](0);
    bytes[] memory buysData = new bytes[](2);
    buysData[0] = abi.encode(address(this), uint256(500));
    buysData[1] = abi.encode(address(this), uint256(200));
    bytes[] memory sellsData = new bytes[](0);

    vm.expectRevert("buys not sorted");
    hook.batch(buys, sells, buysData, sellsData);
  }

  /// @notice Sells array not sorted ascending by amountIn must revert.
  function testBatch_RevertsUnsortedSells() public {
    AsyncOrder[] memory buys = new AsyncOrder[](0);
    AsyncOrder[] memory sells = new AsyncOrder[](2);
    sells[0] = _sell(800);
    sells[1] = _sell(300); // 800 > 300 — not sorted ascending

    bytes[] memory buysData = new bytes[](0);
    bytes[] memory sellsData = new bytes[](2);
    sellsData[0] = abi.encode(address(this), uint256(800));
    sellsData[1] = abi.encode(address(this), uint256(300));

    vm.expectRevert("sells not sorted");
    hook.batch(buys, sells, buysData, sellsData);
  }

  // ─── data length mismatch ─────────────────────────────────────────────────

  /// @notice Mismatched buysData length must revert.
  function testBatch_RevertsBuysDataLengthMismatch() public {
    AsyncOrder[] memory buys = new AsyncOrder[](2);
    buys[0] = _buy(100);
    buys[1] = _buy(200);

    AsyncOrder[] memory sells = new AsyncOrder[](0);
    bytes[] memory buysData = new bytes[](1); // wrong length
    buysData[0] = abi.encode(address(this), uint256(100));
    bytes[] memory sellsData = new bytes[](0);

    vm.expectRevert("buys data length mismatch");
    hook.batch(buys, sells, buysData, sellsData);
  }

  /// @notice Mismatched sellsData length must revert.
  function testBatch_RevertsSellsDataLengthMismatch() public {
    AsyncOrder[] memory buys = new AsyncOrder[](0);
    AsyncOrder[] memory sells = new AsyncOrder[](2);
    sells[0] = _sell(100);
    sells[1] = _sell(200);

    bytes[] memory buysData = new bytes[](0);
    bytes[] memory sellsData = new bytes[](1); // wrong length
    sellsData[0] = abi.encode(address(this), uint256(100));

    vm.expectRevert("sells data length mismatch");
    hook.batch(buys, sells, buysData, sellsData);
  }

}
