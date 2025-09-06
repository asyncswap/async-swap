// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { CurrencyLibrary } from "v4-core/types/Currency.sol";

contract RouterTest is SetupHook {

  using CurrencyLibrary for Currency;

  address testUser = makeAddr("testUser");
  address testUser2 = makeAddr("testUser2");
  address invalidExecutor = makeAddr("invalidExecutor");

  function setUp() public override {
    super.setUp();
    topUp(testUser, 10 ether);
    topUp(testUser2, 10 ether);
  }

  function testSwapWithValidExecutor() public {
    uint256 swapAmount = 1000;

    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Verify swap was successful
    assertEq(hook.asyncOrder(poolId, testUser, true), swapAmount);
    assertTrue(hook.isExecutor(poolId, testUser, address(router)));
  }

  function testSwapFailsWithInvalidExecutor() public {
    uint256 swapAmount = 1000;

    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    vm.expectRevert("Use router as your executor!");
    router.swap(swapOrder, abi.encode(testUser, invalidExecutor));
    vm.stopPrank();
  }

  function testFillOrderSuccessful() public {
    uint256 swapAmount = 1000;

    // First create an async order
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Now fill the order
    AsyncOrder memory fillOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    vm.startPrank(testUser2);
    token1.approve(address(router), swapAmount);
    router.fillOrder(fillOrder, "");
    vm.stopPrank();

    // Verify order was filled
    assertEq(hook.asyncOrder(poolId, testUser, true), 0);
  }

  function testUnlockCallbackOnlyPoolManager() public {
    vm.prank(testUser);
    vm.expectRevert("Caller is not PoolManager");
    router.unlockCallback("");
  }

  function testSwapZeroForOneFalse() public {
    uint256 swapAmount = 1000;

    vm.startPrank(testUser);
    token1.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder = AsyncOrder({
      key: key,
      owner: testUser,
      zeroForOne: false, // currency1 to currency0
      amountIn: swapAmount,
      sqrtPrice: 2 ** 96
    });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Verify swap was successful
    assertEq(hook.asyncOrder(poolId, testUser, false), swapAmount);
    assertTrue(hook.isExecutor(poolId, testUser, address(router)));
  }

  function testFillOrderZeroForOneFalse() public {
    uint256 swapAmount = 1000;

    // First create an async order (currency1 to currency0)
    vm.startPrank(testUser);
    token1.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: false, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Now fill the order (need to provide currency0)
    AsyncOrder memory fillOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: false, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    vm.startPrank(testUser2);
    token0.approve(address(router), swapAmount);
    router.fillOrder(fillOrder, "");
    vm.stopPrank();

    // Verify order was filled
    assertEq(hook.asyncOrder(poolId, testUser, false), 0);
  }

  function testRouterConstants() public view {
    // Test that router has the expected immutable values
    // Note: These are immutable variables, we test indirectly by ensuring operations work
    assertTrue(address(router) != address(0));
    assertTrue(address(manager) != address(0));
    assertTrue(address(hook) != address(0));
  }

  function testMultipleSwapsAndFills() public {
    uint256 swapAmount1 = 500;
    uint256 swapAmount2 = 800;

    // User 1 creates first async order
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount1);

    AsyncOrder memory swapOrder1 =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount1, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder1, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // User 1 creates second async order (accumulates)
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount2);

    AsyncOrder memory swapOrder2 =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount2, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder2, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Verify accumulated amount
    assertEq(hook.asyncOrder(poolId, testUser, true), swapAmount1 + swapAmount2);

    // Fill partial amount
    AsyncOrder memory fillOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount1, sqrtPrice: 2 ** 96 });

    vm.startPrank(testUser2);
    token1.approve(address(router), swapAmount1);
    router.fillOrder(fillOrder, "");
    vm.stopPrank();

    // Verify partial fill
    assertEq(hook.asyncOrder(poolId, testUser, true), swapAmount2);

    // Fill remaining
    AsyncOrder memory fillOrder2 =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount2, sqrtPrice: 2 ** 96 });

    vm.startPrank(testUser2);
    token1.approve(address(router), swapAmount2);
    router.fillOrder(fillOrder2, "");
    vm.stopPrank();

    // Verify complete fill
    assertEq(hook.asyncOrder(poolId, testUser, true), 0);
  }

  function testSwapBalanceChanges() public {
    uint256 swapAmount = 1000;
    uint256 initialBalance0 = token0.balanceOf(testUser);
    uint256 initialBalance1 = token1.balanceOf(testUser);

    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Verify balance changes
    assertEq(token0.balanceOf(testUser), initialBalance0 - swapAmount);
    assertEq(token1.balanceOf(testUser), initialBalance1); // Should be unchanged
  }

  function testFillOrderBalanceChanges() public {
    uint256 swapAmount = 1000;

    // Setup async order
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Record balances before fill
    uint256 filler_balance0_before = token0.balanceOf(testUser2);
    uint256 filler_balance1_before = token1.balanceOf(testUser2);

    // Fill order
    AsyncOrder memory fillOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    vm.startPrank(testUser2);
    token1.approve(address(router), swapAmount);
    router.fillOrder(fillOrder, "");
    vm.stopPrank();

    // Verify balance changes
    assertEq(token1.balanceOf(testUser2), filler_balance1_before - swapAmount);
    assertEq(token0.balanceOf(testUser2), filler_balance0_before); // Should be unchanged
    // User should receive claimable tokens in manager
    assertEq(manager.balanceOf(testUser, currency0.toId()), uint256(swapAmount));
  }

  function testFuzzSwapAmounts(uint256 amount, bool zeroForOne) public {
    vm.assume(amount > 0);
    vm.assume(amount <= 5 ether);

    topUp(testUser, amount);

    vm.startPrank(testUser);
    if (zeroForOne) {
      token0.approve(address(router), amount);
    } else {
      token1.approve(address(router), amount);
    }

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: zeroForOne, amountIn: amount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    assertEq(hook.asyncOrder(poolId, testUser, zeroForOne), amount);
  }

}
