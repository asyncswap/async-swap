// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { Currency } from "v4-core/interfaces/IPoolManager.sol";
import { CurrencyLibrary } from "v4-core/types/Currency.sol";

/// @title Multicall Test
/// @notice Tests that multicall handles individual order failures gracefully
contract MulticallTest is SetupHook {

  using CurrencyLibrary for Currency;

  address user1 = makeAddr("user1");
  address user2 = makeAddr("user2");
  address user3 = makeAddr("user3");
  address filler = makeAddr("filler");

  function setUp() public override {
    super.setUp();
    topUp(user1, 10 ether);
    topUp(user2, 10 ether);
    topUp(user3, 10 ether);
    topUp(filler, 100 ether);
  }

  /// @notice Test that multicall continues executing even when some orders fail
  function testMulticallHandlesFailuresGracefully() public {
    // Create 3 orders
    AsyncOrder memory order1 = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user1,
      zeroForOne: true,
      amountIn: 1 ether,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    AsyncOrder memory order2 = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user2,
      zeroForOne: true,
      amountIn: 2 ether,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    AsyncOrder memory order3 = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user3,
      zeroForOne: true,
      amountIn: 3 ether,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    // User1, User2, User3 create orders and set router as executor
    vm.startPrank(user1);
    token0.approve(address(router), 1 ether);
    router.swap(order1, abi.encode(user1, address(router)));
    vm.stopPrank();

    vm.startPrank(user2);
    token0.approve(address(router), 2 ether);
    router.swap(order2, abi.encode(user2, address(router)));
    vm.stopPrank();

    vm.startPrank(user3);
    token0.approve(address(router), 3 ether);
    router.swap(order3, abi.encode(user3, address(router)));
    vm.stopPrank();

    // Verify all orders created
    assertEq(hook.asyncOrderAmount(poolId, user1, true), 1 ether);
    assertEq(hook.asyncOrderAmount(poolId, user2, true), 2 ether);
    assertEq(hook.asyncOrderAmount(poolId, user3, true), 3 ether);

    // Verify router is executor for all users
    assertTrue(hook.isExecutor(poolId, user1, address(router)));
    assertTrue(hook.isExecutor(poolId, user2, address(router)));
    assertTrue(hook.isExecutor(poolId, user3, address(router)));

    // User2 CANCELS their order (withdraws)
    vm.startPrank(user2);
    router.withdraw(key, true, 2 ether);
    vm.stopPrank();

    // Verify user2's order is cancelled
    assertEq(hook.asyncOrderAmount(poolId, user2, true), 0);

    // Now filler tries to fill all 3 orders using multicall
    AsyncOrder[] memory orders = new AsyncOrder[](3);
    orders[0] = order1;
    orders[1] = order2; // This one will fail (cancelled)
    orders[2] = order3;

    bytes[] memory ordersData = new bytes[](3);
    ordersData[0] = abi.encode(filler, 1 ether);
    ordersData[1] = abi.encode(filler, 2 ether);
    ordersData[2] = abi.encode(filler, 3 ether);

    // Execute multicall - filler needs to approve tokens to manager
    vm.startPrank(filler);

    // Debug: Check filler's token1 balance
    uint256 fillerBalance = token1.balanceOf(filler);
    assertGt(fillerBalance, 0, "Filler has no token1 balance!");

    token1.approve(address(router), 100 ether);
    bool[] memory results = router.multicall(orders, ordersData);
    vm.stopPrank();

    // Verify results: order1 success, order2 failed, order3 success
    assertTrue(results[0], "Order1 should succeed");
    assertFalse(results[1], "Order2 should fail (cancelled)");
    assertTrue(results[2], "Order3 should succeed");

    // Verify: Order1 and Order3 were filled, Order2 was not
    assertEq(hook.asyncOrderAmount(poolId, user1, true), 0, "Order1 should be filled");
    assertEq(hook.asyncOrderAmount(poolId, user2, true), 0, "Order2 already cancelled");
    assertEq(hook.asyncOrderAmount(poolId, user3, true), 0, "Order3 should be filled");
  }

  /// @notice Test that expired orders don't revert the entire multicall
  function testMulticallHandlesExpiredOrders() public {
    // Create 2 orders: one that expires, one that doesn't
    AsyncOrder memory validOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user1,
      zeroForOne: true,
      amountIn: 1 ether,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    AsyncOrder memory expiredOrder = AsyncOrder({
      deadline: block.timestamp + 10 minutes,
      key: key,
      owner: user2,
      zeroForOne: true,
      amountIn: 2 ether,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    // Create orders with router as executor
    vm.startPrank(user1);
    token0.approve(address(router), 1 ether);
    router.swap(validOrder, abi.encode(user1, address(router)));
    vm.stopPrank();

    vm.startPrank(user2);
    token0.approve(address(router), 2 ether);
    router.swap(expiredOrder, abi.encode(user2, address(router)));
    vm.stopPrank();

    // Fast forward past expiredOrder's deadline
    vm.warp(block.timestamp + 15 minutes);

    // Try to fill both orders
    AsyncOrder[] memory orders = new AsyncOrder[](2);
    orders[0] = validOrder;
    orders[1] = expiredOrder; // This will fail (expired)

    bytes[] memory ordersData = new bytes[](2);
    ordersData[0] = abi.encode(filler, 1 ether);
    ordersData[1] = abi.encode(filler, 2 ether);

    vm.startPrank(filler);
    token1.approve(address(router), 100 ether);
    bool[] memory results = router.multicall(orders, ordersData);
    vm.stopPrank();

    // Verify: validOrder succeeded, expiredOrder failed
    assertTrue(results[0], "Valid order should succeed");
    assertFalse(results[1], "Expired order should fail");

    // Valid order was filled
    assertEq(hook.asyncOrderAmount(poolId, user1, true), 0);
    // Expired order was not filled (user can still withdraw)
    assertEq(hook.asyncOrderAmount(poolId, user2, true), 2 ether);
  }

  /// @notice Test that slippage violations don't revert entire multicall
  function testMulticallHandlesSlippageViolations() public {
    // Create 2 orders with different slippage requirements
    AsyncOrder memory flexibleOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user1,
      zeroForOne: true,
      amountIn: 1 ether,
      minAmountOut: 0.5 ether, // Very flexible
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    AsyncOrder memory strictOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user2,
      zeroForOne: true,
      amountIn: 2 ether,
      minAmountOut: 2.5 ether, // Very strict
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    // Create orders with router as executor
    vm.startPrank(user1);
    token0.approve(address(router), 1 ether);
    router.swap(flexibleOrder, abi.encode(user1, address(router)));
    vm.stopPrank();

    vm.startPrank(user2);
    token0.approve(address(router), 2 ether);
    router.swap(strictOrder, abi.encode(user2, address(router)));
    vm.stopPrank();

    // Filler offers 0.9 for both (acceptable for first, not for second)
    AsyncOrder[] memory orders = new AsyncOrder[](2);
    orders[0] = flexibleOrder;
    orders[1] = strictOrder;

    bytes[] memory ordersData = new bytes[](2);
    ordersData[0] = abi.encode(filler, 0.9 ether); // Acceptable (>= 0.5)
    ordersData[1] = abi.encode(filler, 0.9 ether); // NOT acceptable (< 2.5)

    vm.startPrank(filler);
    token1.approve(address(router), 100 ether);
    bool[] memory results = router.multicall(orders, ordersData);
    vm.stopPrank();

    // Verify: flexible succeeded, strict failed
    assertTrue(results[0], "Flexible order should succeed");
    assertFalse(results[1], "Strict order should fail (slippage)");

    // Flexible order filled, strict order remains
    assertEq(hook.asyncOrderAmount(poolId, user1, true), 0);
    assertEq(hook.asyncOrderAmount(poolId, user2, true), 2 ether);
  }
}
