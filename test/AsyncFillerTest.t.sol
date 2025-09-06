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

  function topUp(address _user, uint256 amount) public ownerAction {
    token0.transfer(_user, amount);
    token1.transfer(_user, amount);
  }

  function testIsExecutorTrue() public {
    // First create an async order to establish executor relationship
    vm.startPrank(testUser);
    token0.approve(address(router), 1000);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: 1000, sqrtPrice: 2 ** 96 });

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

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Verify executor is set and order exists
    assertTrue(hook.isExecutor(poolId, testUser, address(router)));
    assertEq(hook.asyncOrder(poolId, testUser, true), swapAmount);

    // Now fill the order
    AsyncOrder memory fillOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    vm.startPrank(testExecutor);
    token1.approve(address(router), swapAmount);
    router.fillOrder(fillOrder, abi.encode(address(router)));
    vm.stopPrank();

    // Verify order was filled
    assertEq(hook.asyncOrder(poolId, testUser, true), 0);
  }

  function testExecuteOrderFailsWithInvalidExecutor() public {
    // First create an async order by swapping
    uint256 swapAmount = 1000;

    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Give nonExecutor enough tokens
    topUp(nonExecutor, swapAmount);

    // Try to fill with non-executor - this should fail at executor validation
    AsyncOrder memory fillOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    vm.startPrank(nonExecutor);
    token1.approve(address(router), swapAmount);
    vm.expectRevert("Caller is valid not excutor");
    hook.executeOrder(fillOrder, "");
    vm.stopPrank();
  }

  function testExecuteOrderPartialFill() public {
    uint256 swapAmount = 1000;
    uint256 fillAmount = 500;

    // Create async order
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Partially fill the order
    AsyncOrder memory fillOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: fillAmount, sqrtPrice: 2 ** 96 });

    vm.startPrank(testExecutor);
    token1.approve(address(router), fillAmount);
    router.fillOrder(fillOrder, abi.encode(address(router)));
    vm.stopPrank();

    // Verify partial fill
    assertEq(hook.asyncOrder(poolId, testUser, true), swapAmount - fillAmount);
  }

  function testExecuteOrderExceedsClaimableAmount() public {
    uint256 swapAmount = 1000;
    uint256 excessFillAmount = 1500;

    // Create async order
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Try to fill more than available
    AsyncOrder memory fillOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: excessFillAmount, sqrtPrice: 2 ** 96 });

    vm.startPrank(testExecutor);
    token1.approve(address(router), excessFillAmount);
    vm.expectRevert("Max fill order limit exceed");
    router.fillOrder(fillOrder, abi.encode(address(router)));
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

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Fill the order
    AsyncOrder memory fillOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: fillAmount, sqrtPrice: 2 ** 96 });

    vm.startPrank(testExecutor);
    token1.approve(address(router), fillAmount);
    router.fillOrder(fillOrder, abi.encode(address(router)));
    vm.stopPrank();

    // Verify fill
    assertEq(hook.asyncOrder(poolId, testUser, true), swapAmount - fillAmount);
  }

  function testExecuteOrderZeroAmount() public {
    uint256 swapAmount = 1000;

    // Create async order
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Try to fill with zero amount
    AsyncOrder memory fillOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: 0, sqrtPrice: 2 ** 96 });

    vm.startPrank(testExecutor);
    vm.expectRevert("ZeroFillOrder()");
    hook.executeOrder(fillOrder, "");
    vm.stopPrank();
  }

  function testExecuteOrderBatchMode() public {
    uint256 swapAmount1 = 1000;
    uint256 swapAmount2 = 800;
    address testUser2 = makeAddr("testUser2");

    topUp(testUser2, swapAmount2);

    // Create first async order and set router as executor
    vm.startPrank(testUser);
    token0.approve(address(router), swapAmount1);
    AsyncOrder memory swapOrder1 =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount1, sqrtPrice: 2 ** 96 });
    router.swap(swapOrder1, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Create second async order and set router as executor
    vm.startPrank(testUser2);
    token0.approve(address(router), swapAmount2);
    AsyncOrder memory swapOrder2 =
      AsyncOrder({ key: key, owner: testUser2, zeroForOne: true, amountIn: swapAmount2, sqrtPrice: 2 ** 96 });
    router.swap(swapOrder2, abi.encode(testUser2, address(router)));
    vm.stopPrank();

    // Execute both orders individually (since router does the execution)
    AsyncOrder memory fillOrder1 =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: true, amountIn: swapAmount1, sqrtPrice: 2 ** 96 });
    AsyncOrder memory fillOrder2 =
      AsyncOrder({ key: key, owner: testUser2, zeroForOne: true, amountIn: swapAmount2, sqrtPrice: 2 ** 96 });

    vm.startPrank(testExecutor);
    token1.approve(address(router), swapAmount1 + swapAmount2);

    router.fillOrder(fillOrder1, abi.encode(address(router)));
    router.fillOrder(fillOrder2, abi.encode(address(router)));
    vm.stopPrank();

    // Verify both orders were filled
    assertEq(hook.asyncOrder(poolId, testUser, true), 0);
    assertEq(hook.asyncOrder(poolId, testUser2, true), 0);
  }

  function testExecuteOrderZeroForOneFalse() public {
    uint256 swapAmount = 1000;

    // Create async order (zeroForOne = false)
    vm.startPrank(testUser);
    token1.approve(address(router), swapAmount);

    AsyncOrder memory swapOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: false, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    router.swap(swapOrder, abi.encode(testUser, address(router)));
    vm.stopPrank();

    // Fill the order
    AsyncOrder memory fillOrder =
      AsyncOrder({ key: key, owner: testUser, zeroForOne: false, amountIn: swapAmount, sqrtPrice: 2 ** 96 });

    vm.startPrank(testExecutor);
    token0.approve(address(router), swapAmount);
    router.fillOrder(fillOrder, abi.encode(address(router)));
    vm.stopPrank();

    // Verify order was filled
    assertEq(hook.asyncOrder(poolId, testUser, false), 0);
  }

}
