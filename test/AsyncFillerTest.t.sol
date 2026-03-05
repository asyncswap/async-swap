// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { Currency, CurrencyLibrary } from "v4-core/PoolManager.sol";

contract AsyncFillerTest is SetupHook {

  using CurrencyLibrary for Currency;

  address testUser = makeAddr("testUser");
  address testExecutor = makeAddr("testExecutor");
  address nonExecutor = makeAddr("nonExecutor");

  function setUp() public override {
    super.setUp();
    topUp(testUser, 10 ether);
    topUp(testExecutor, 10 ether);
  }

  function testIsExecutorTrue() public {
    // First create an async order to establish executor relationship
    vm.startPrank(testUser);
    token0.approve(address(router), 1000);

    AsyncOrder memory swapOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: 1000,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    bool result = hook.isExecutor(poolId, testUser, address(router));
    assertTrue(result);
  }

  function testIsExecutorFalse() public view {
    bool result = hook.isExecutor(poolId, testUser, nonExecutor);
    assertFalse(result);
  }

  function testExecuteOrderWithValidExecutor() public {
    // First create an async order by swapping
    uint256 swapAmount = 1000;

    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Verify executor is set and order exists
    assertTrue(hook.isExecutor(poolId, testUser, address(router)));
    assertEq(hook.asyncOrderAmount(poolId, testUser, true), swapAmount);

    // Now fill the order
    AsyncOrder memory fillOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    vm.startPrank(testExecutor);
    token1.approve(address(router), swapAmount);
    router.fillOrder(fillOrder, abi.encode(fillOrder.amountIn));
    vm.stopPrank();

    // Verify order was filled
    assertEq(hook.asyncOrderAmount(poolId, testUser, true), 0);
  }

  function testExecuteOrderFailsWithInvalidExecutor() public {
    // First create an async order by swapping
    uint256 swapAmount = 1000;

    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Give nonExecutor enough tokens
    topUp(nonExecutor, swapAmount);

    // Try to fill with non-executor - this should fail at executor validation
    AsyncOrder memory fillOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    vm.startPrank(nonExecutor);
    token1.approve(address(router), swapAmount);
    vm.expectRevert("Caller is not valid executor");
    hook.executeOrder(fillOrder, abi.encode(nonExecutor, swapAmount));
    vm.stopPrank();
  }

  function testExecuteOrderPartialFill() public {
    uint256 swapAmount = 1000;
    uint256 fillAmount = 500;

    // Create async order
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Partially fill the order
    AsyncOrder memory fillOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: fillAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    vm.startPrank(testExecutor);
    token1.approve(address(router), fillAmount);
    router.fillOrder(fillOrder, abi.encode(fillOrder.amountIn));
    vm.stopPrank();

    // Verify partial fill
    assertEq(hook.asyncOrderAmount(poolId, testUser, true), swapAmount - fillAmount);
  }

  function testExecuteOrderExceedsClaimableAmount() public {
    uint256 swapAmount = 1000;
    uint256 excessFillAmount = 1500;

    // Create async order
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Try to fill more than available
    AsyncOrder memory fillOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: excessFillAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    vm.startPrank(testExecutor);
    token1.approve(address(router), excessFillAmount);
    vm.expectRevert("Max fill order limit exceed");
    router.fillOrder(fillOrder, abi.encode(fillOrder.amountIn));
    vm.stopPrank();
  }

  function testFuzzExecuteOrder(uint256 swapAmount, uint256 fillAmount) public {
    vm.assume(swapAmount > 0);
    vm.assume(swapAmount <= 1 ether);
    vm.assume(fillAmount > 0);
    vm.assume(fillAmount <= swapAmount);

    topUp(testUser, swapAmount);
    topUp(testExecutor, fillAmount);

    // Create async order
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Fill the order
    AsyncOrder memory fillOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: fillAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    vm.startPrank(testExecutor);
    token1.approve(address(router), fillAmount);
    router.fillOrder(fillOrder, abi.encode(fillOrder.amountIn));
    vm.stopPrank();

    // Verify fill
    assertEq(hook.asyncOrderAmount(poolId, testUser, true), swapAmount - fillAmount);
  }

  function testFuzz_ExecuteOrderBatchMode(uint256 swapAmount1, uint256 swapAmount2) public {
    swapAmount1 = 1000;
    swapAmount2 = 800;
    address testUser2 = makeAddr("testUser2");

    topUp(testUser2, swapAmount2);

    // Create first async order and set router as executor
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount1);
    AsyncOrder memory swapOrder1 = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: swapAmount1,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });
    router.swap(swapOrder1, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Create second async order and set router as executor
    vm.startPrank(testUser2);
    token0.approve(address(router), swapAmount2);
    AsyncOrder memory swapOrder2 = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser2,
      zeroForOne: true,
      amountIn: swapAmount2,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });
    router.swap(swapOrder2, abi.encode(testUser2, address(router)));
    vm.stopPrank();

    // Execute both orders individually (since router does the execution)
    AsyncOrder memory fillOrder1 = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: true,
      amountIn: swapAmount1,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });
    AsyncOrder memory fillOrder2 = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser2,
      zeroForOne: true,
      amountIn: swapAmount2,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    vm.startPrank(testExecutor);
    token1.approve(address(router), swapAmount1 + swapAmount2);

    router.fillOrder(fillOrder1, abi.encode(fillOrder1.amountIn));
    router.fillOrder(fillOrder2, abi.encode(fillOrder2.amountIn));
    vm.stopPrank();

    // Verify both orders were filled
    assertEq(hook.asyncOrderAmount(poolId, testUser, true), 0);
    assertEq(hook.asyncOrderAmount(poolId, testUser2, true), 0);
  }

  function testExecuteOrderZeroForOneFalse() public {
    uint256 swapAmount = 1000;

    // Create async order (zeroForOne = false)
    vm.startPrank(testUser);
    token1.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: false,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Fill the order
    AsyncOrder memory fillOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: false,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    vm.startPrank(testExecutor);
    token0.approve(address(router), swapAmount);
    router.fillOrder(fillOrder, abi.encode(fillOrder.amountIn));
    vm.stopPrank();

    // Verify order was filled
    assertEq(hook.asyncOrderAmount(poolId, testUser, false), 0);
  }

  /// @notice ERC-6909 accounting invariant: after a fill, filler receives exactly amountIn
  ///         as ERC-6909 claims and user receives exactly amountOut as ERC20.
  function testFuzz_ERC6909AccountingInvariant(uint256 amountIn, uint256 amountOut, bool zeroForOne) public {
    amountIn = bound(amountIn, 1, 1 ether);
    amountOut = bound(amountOut, 1, 1 ether);

    topUp(testUser, amountIn);
    topUp(testExecutor, amountOut);

    // --- Snapshot balances before order creation ---

    // Create async order
    vm.startPrank(testUser);
    if (zeroForOne) {
      token0.approve(address(router), amountIn);
    } else {
      token1.approve(address(router), amountIn);
    }

    AsyncOrder memory order = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: testUser,
      zeroForOne: zeroForOne,
      amountIn: amountIn,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    router.swap(order, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // --- Snapshot balances before fill ---

    // Filler's ERC-6909 claim balance for the INPUT currency (what user escrowed)
    uint256 fillerInputCurrencyId = zeroForOne ? currency0.toId() : currency1.toId();
    uint256 fillerClaimsBefore = manager.balanceOf(testExecutor, fillerInputCurrencyId);

    // User's ERC20 balance for the OUTPUT currency (what filler provides)
    uint256 userOutputBefore = zeroForOne ? token1.balanceOf(testUser) : token0.balanceOf(testUser);

    // Hook's ERC-6909 claims for the INPUT currency (escrowed tokens)
    uint256 hookClaimsBefore = manager.balanceOf(address(hook), fillerInputCurrencyId);

    // --- Fill the order ---
    vm.startPrank(testExecutor);
    if (zeroForOne) {
      token1.approve(address(router), amountOut);
    } else {
      token0.approve(address(router), amountOut);
    }
    router.fillOrder(order, abi.encode(amountOut));
    vm.stopPrank();

    // --- Verify invariants ---

    // 1. Filler receives exactly amountIn as ERC-6909 claims
    uint256 fillerClaimsAfter = manager.balanceOf(testExecutor, fillerInputCurrencyId);
    assertEq(
      fillerClaimsAfter - fillerClaimsBefore, amountIn, "Filler ERC-6909 claims must increase by exactly amountIn"
    );

    // 2. User receives exactly amountOut as ERC20
    uint256 userOutputAfter = zeroForOne ? token1.balanceOf(testUser) : token0.balanceOf(testUser);
    assertEq(userOutputAfter - userOutputBefore, amountOut, "User ERC20 balance must increase by exactly amountOut");

    // 3. Hook's escrowed claims decrease by exactly amountIn (tokens transferred to filler)
    uint256 hookClaimsAfter = manager.balanceOf(address(hook), fillerInputCurrencyId);
    assertEq(hookClaimsBefore - hookClaimsAfter, amountIn, "Hook ERC-6909 claims must decrease by exactly amountIn");

    // 4. Claimable amount for user is now 0
    assertEq(hook.asyncOrderAmount(poolId, testUser, zeroForOne), 0, "Claimable must be zero after full fill");
  }

}
