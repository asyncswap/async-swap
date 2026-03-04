// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { Currency } from "v4-core/interfaces/IPoolManager.sol";
import { CurrencyLibrary } from "v4-core/types/Currency.sol";

contract IntegrationTest is SetupHook {

  using CurrencyLibrary for Currency;

  address alice = makeAddr("alice");
  address bob = makeAddr("bob");
  address charlie = makeAddr("charlie");

  function setUp() public override {
    super.setUp();
    topUp(alice, 50 ether);
    topUp(bob, 50 ether);
    topUp(charlie, 50 ether);
  }

  function testCompleteSwapAndFillWorkflow() public {
    uint256 swapAmount = 2 ether;

    // Alice creates async swap order
    vm.startPrank(alice);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory aliceOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: alice,
      zeroForOne: true,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(aliceOrder, abi.encode(alice, address(router)));
    vm.stopPrank();

    // Verify Alice's order
    assertEq(hook.asyncOrderAmount(poolId, alice, true), swapAmount);
    assertTrue(hook.isExecutor(poolId, alice, address(router)));

    // Bob fills Alice's order
    uint256 aliceToken1Before = token1.balanceOf(alice);
    vm.startPrank(bob);
    token1.approve(address(router), swapAmount);
    router.fillOrder(aliceOrder, abi.encode(aliceOrder.amountIn));
    vm.stopPrank();

    // Verify order completion — alice receives token1 as ERC20 (delta)
    assertEq(hook.asyncOrderAmount(poolId, alice, true), 0);
    assertEq(token1.balanceOf(alice) - aliceToken1Before, swapAmount);
  }

  function testMultipleUsersMultipleOrders() public {
    uint256 aliceAmount = 1 ether;
    uint256 bobAmount = 1.5 ether;

    // Alice creates order (zeroForOne = true)
    vm.startPrank(alice);
    token0.approve(address(router), aliceAmount);

    AsyncOrder memory aliceOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: alice,
      zeroForOne: true,
      amountIn: aliceAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(aliceOrder, abi.encode(alice, address(router)));
    vm.stopPrank();

    // Bob creates order (zeroForOne = false)
    vm.startPrank(bob);
    token1.approve(address(router), bobAmount);

    AsyncOrder memory bobOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: bob,
      zeroForOne: false,
      amountIn: bobAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(bobOrder, abi.encode(bob, address(router)));
    vm.stopPrank();

    // Verify both orders exist
    assertEq(hook.asyncOrderAmount(poolId, alice, true), aliceAmount);
    assertEq(hook.asyncOrderAmount(poolId, bob, false), bobAmount);

    // Charlie fills Alice's order
    vm.startPrank(charlie);
    token1.approve(address(router), aliceAmount);
    router.fillOrder(aliceOrder, abi.encode(aliceOrder.amountIn));
    vm.stopPrank();

    // Charlie fills Bob's order
    vm.startPrank(charlie);
    token0.approve(address(router), bobAmount);

    AsyncOrder memory bobFillOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: bob,
      zeroForOne: false,
      amountIn: bobAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.fillOrder(bobFillOrder, abi.encode(bobFillOrder.amountIn));
    vm.stopPrank();

    // Verify all orders filled
    assertEq(hook.asyncOrderAmount(poolId, alice, true), 0);
    assertEq(hook.asyncOrderAmount(poolId, bob, false), 0);
  }

  function testPartialFillsAndAccumulation() public {
    uint256 totalAmount = 3 ether;
    uint256 firstSwap = 1 ether;
    uint256 secondSwap = 2 ether;
    uint256 firstFill = 1.5 ether;
    uint256 secondFill = 1.5 ether;

    // Alice creates first order
    vm.startPrank(alice);
    token0.approve(address(router), firstSwap);

    AsyncOrder memory aliceOrder1 = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: alice,
      zeroForOne: true,
      amountIn: firstSwap,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(aliceOrder1, abi.encode(alice, address(router)));
    assertEq(hook.asyncOrderAmount(poolId, alice, true), firstSwap);

    // Alice creates second order (accumulates)
    token0.approve(address(router), secondSwap);

    AsyncOrder memory aliceOrder2 = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: alice,
      zeroForOne: true,
      amountIn: secondSwap,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(aliceOrder2, abi.encode(alice, address(router)));
    vm.stopPrank();

    // Verify accumulated amount
    assertEq(hook.asyncOrderAmount(poolId, alice, true), totalAmount);

    // Bob partially fills
    vm.startPrank(bob);
    token1.approve(address(router), firstFill);

    AsyncOrder memory fillOrder1 = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: alice,
      zeroForOne: true,
      amountIn: firstFill,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.fillOrder(fillOrder1, abi.encode(fillOrder1.amountIn));
    vm.stopPrank();

    // Verify partial fill
    assertEq(hook.asyncOrderAmount(poolId, alice, true), totalAmount - firstFill);

    // Charlie fills remainder
    vm.startPrank(charlie);
    token1.approve(address(router), secondFill);

    AsyncOrder memory fillOrder2 = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: alice,
      zeroForOne: true,
      amountIn: secondFill,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.fillOrder(fillOrder2, abi.encode(fillOrder2.amountIn));
    vm.stopPrank();

    // Verify complete fill
    assertEq(hook.asyncOrderAmount(poolId, alice, true), 0);
  }

  function testBatchOrderExecution() public {
    uint256 orderCount = 5;
    uint256 amountPerOrder = 0.5 ether;

    // Alice creates multiple orders
    vm.startPrank(alice);
    for (uint256 i = 0; i < orderCount; i++) {
      token0.approve(address(router), amountPerOrder);

      AsyncOrder memory order = AsyncOrder({
        deadline: block.timestamp + 1 hours,
        key: key,
        owner: alice,
        zeroForOne: true,
        amountIn: amountPerOrder,
        minAmountOut: 0,
        maxAmountIn: 0,
        sqrtPrice: 2 ** 96
      });

      router.swap(order, abi.encode(alice, address(router)));
    }
    vm.stopPrank();

    // Verify total accumulated
    assertEq(hook.asyncOrderAmount(poolId, alice, true), orderCount * amountPerOrder);

    // Execute orders one by one using router (since alice set router as executor)
    for (uint256 i = 0; i < orderCount; i++) {
      AsyncOrder memory fillOrder = AsyncOrder({
        deadline: block.timestamp + 1 hours,
        key: key,
        owner: alice,
        zeroForOne: true,
        amountIn: amountPerOrder,
        minAmountOut: 0,
        maxAmountIn: 0,
        sqrtPrice: 2 ** 96
      });

      vm.startPrank(bob);
      token1.approve(address(router), amountPerOrder);
      router.fillOrder(fillOrder, abi.encode(fillOrder.amountIn));
      vm.stopPrank();
    }

    // Verify all orders executed
    assertEq(hook.asyncOrderAmount(poolId, alice, true), 0);
  }

  function testCrossDirectionalOrders() public {
    uint256 amount = 1 ether;

    // Alice: token0 -> token1 (zeroForOne = true)
    vm.startPrank(alice);
    token0.approve(address(router), amount);

    AsyncOrder memory aliceOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: alice,
      zeroForOne: true,
      amountIn: amount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(aliceOrder, abi.encode(alice, address(router)));
    vm.stopPrank();

    // Bob: token1 -> token0 (zeroForOne = false)
    vm.startPrank(bob);
    token1.approve(address(router), amount);

    AsyncOrder memory bobOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours, key: key, owner: bob, zeroForOne: false, amountIn: amount,
      minAmountOut: 0,
      maxAmountIn: 0, sqrtPrice: 2 ** 96
    });

    router.swap(bobOrder, abi.encode(bob, address(router)));
    vm.stopPrank();

    // Charlie can fill both orders
    vm.startPrank(charlie);

    // Fill Alice's order (needs token1)
    token1.approve(address(router), amount);
    router.fillOrder(aliceOrder, abi.encode(aliceOrder.amountIn));

    // Fill Bob's order (needs token0)
    token0.approve(address(router), amount);
    router.fillOrder(bobOrder, abi.encode(bobOrder.amountIn));

    vm.stopPrank();

    // Verify both filled
    assertEq(hook.asyncOrderAmount(poolId, alice, true), 0);
    assertEq(hook.asyncOrderAmount(poolId, bob, false), 0);
  }

  function testAlgorithmIntegration() public {
    uint256 amount = 1 ether;

    // Verify algorithm is set correctly
    address algorithmAddress = address(hook.ALGORITHM());
    assertTrue(algorithmAddress != address(0));

    // Create order to trigger algorithm
    vm.startPrank(alice);
    token0.approve(address(router), amount);

    AsyncOrder memory order = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: alice,
      zeroForOne: true,
      amountIn: amount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(order, abi.encode(alice, address(router)));
    vm.stopPrank();

    // The swap should succeed, meaning algorithm was called successfully
    assertEq(hook.asyncOrderAmount(poolId, alice, true), amount);
  }

  function testLargeVolumeStressTest() public {
    uint256 userCount = 10;
    uint256 amountPerUser = 0.1 ether;

    // Multiple users create orders
    for (uint256 i = 0; i < userCount; i++) {
      address user = address(uint160(i + 1000)); // Generate unique addresses
      topUp(user, amountPerUser);

      vm.startPrank(user);
      token0.approve(address(router), amountPerUser);

      AsyncOrder memory order = AsyncOrder({
        deadline: block.timestamp + 1 hours,
        key: key,
        owner: user,
        zeroForOne: true,
        amountIn: amountPerUser,
        minAmountOut: 0,
        maxAmountIn: 0,
        sqrtPrice: 2 ** 96
      });

      router.swap(order, abi.encode(user, address(router)));
      vm.stopPrank();

      // Verify each order
      assertEq(hook.asyncOrderAmount(poolId, user, true), amountPerUser);
    }

    // Single filler fills all orders
    vm.startPrank(charlie);
    token1.approve(address(router), userCount * amountPerUser);

    for (uint256 i = 0; i < userCount; i++) {
      address user = address(uint160(i + 1000));

      AsyncOrder memory fillOrder = AsyncOrder({
        deadline: block.timestamp + 1 hours,
        key: key,
        owner: user,
        zeroForOne: true,
        amountIn: amountPerUser,
        minAmountOut: 0,
        maxAmountIn: 0,
        sqrtPrice: 2 ** 96
      });

      router.fillOrder(fillOrder, abi.encode(fillOrder.amountIn));
      assertEq(hook.asyncOrderAmount(poolId, user, true), 0);
    }
    vm.stopPrank();
  }

}
