// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { Currency } from "v4-core/interfaces/IPoolManager.sol";
import { CurrencyLibrary } from "v4-core/types/Currency.sol";

/// @title Async Swap test contract
contract AsyncSwapTest is SetupHook {

  using CurrencyLibrary for Currency;

  address asyncFiller = makeAddr("asyncFiller");
  address user = makeAddr("user");
  address user2 = makeAddr("user2");

  function setUp() public override {
    super.setUp();
    topUp(user, 1 ether);
    topUp(user2, 2 ether);
    asyncFiller = address(router);
  }

  modifier userAction(address _user) {
    vm.startPrank(_user);
    _;
    vm.stopPrank();
  }

  function swap(address _user, address _asyncFiller, AsyncOrder memory order) public {
    vm.startPrank(_user);
    if (order.zeroForOne) {
      token0.approve(address(router), order.amountIn);
    } else {
      token1.approve(address(router), order.amountIn);
    }
    router.swap(order, abi.encode(user, _asyncFiller));
    vm.stopPrank();
  }

  function fillOrder(address _user, AsyncOrder memory order, address _asyncFiller) public {
    vm.startPrank(_user);
    if (order.zeroForOne) {
      token1.approve(address(router), order.amountIn);
    } else {
      token0.approve(address(router), order.amountIn);
    }
    router.fillOrder(order, abi.encode(_asyncFiller));
    vm.stopPrank();
  }

  function testFuzzAsyncSwapAndFillOrder(address _user, uint256 amountIn, bool zeroForOne) public {
    vm.assume(amountIn >= 1);
    vm.assume(amountIn < 2 ** 96);
    user = _user;
    topUp(user, amountIn);
    topUp(user2, amountIn);

    AsyncOrder memory order =
      AsyncOrder({ key: key, owner: user, zeroForOne: zeroForOne, amountIn: amountIn, sqrtPrice: 2 ** 96 });

    uint256 balance0Before = currency0.balanceOf(user);
    uint256 balance1Before = currency1.balanceOf(user);

    // swap
    swap(user, asyncFiller, order);

    uint256 balance0After = currency0.balanceOf(user);
    uint256 balance1After = currency1.balanceOf(user);

    if (zeroForOne) {
      assertEq(balance0Before - balance0After, amountIn);
      assertEq(balance1Before, balance1After);
    } else {
      assertEq(balance1Before - balance1After, amountIn);
      assertEq(balance0Before, balance0After);
    }
    assertEq(hook.asyncOrder(poolId, user, zeroForOne), amountIn);
    assertEq(hook.isExecutor(poolId, user, asyncFiller), true);

    balance0Before = currency0.balanceOf(user2);
    balance1Before = currency1.balanceOf(user2);

    // fill
    fillOrder(user2, order, asyncFiller);

    balance0After = currency0.balanceOf(user2);
    balance1After = currency1.balanceOf(user2);

    if (zeroForOne) {
      assertEq(balance0Before, balance0After);
      assertEq(balance1Before - balance1After, amountIn);
      assertEq(hook.asyncOrder(poolId, user, zeroForOne), 0);
    } else {
      assertEq(balance1Before, balance1After);
      assertEq(balance0Before - balance0After, amountIn);
      assertEq(hook.asyncOrder(poolId, user, zeroForOne), 0);
    }
    if (zeroForOne) {
      assertEq(manager.balanceOf(user, currency0.toId()), uint256(amountIn));
    } else {
      assertEq(manager.balanceOf(user, currency1.toId()), uint256(amountIn));
    }
  }

  function testFuzzAsyncSwapOrder(bool zeroForOne, uint256 amount) public userAction(user) {
    vm.assume(amount >= 1);
    vm.assume(amount <= 1 ether);

    uint256 balance0Before = manager.balanceOf(address(hook), currency0.toId());
    uint256 balance1Before = manager.balanceOf(address(hook), currency0.toId());

    uint256 userCurrency0Balance = currency0.balanceOf(user);
    uint256 userCurrency1Balance = currency1.balanceOf(user);
    if (zeroForOne) {
      token0.approve(address(router), amount);
    } else {
      token1.approve(address(router), amount);
    }

    AsyncOrder memory order =
      AsyncOrder({ key: key, owner: user, zeroForOne: zeroForOne, amountIn: amount, sqrtPrice: 2 ** 96 });

    router.swap(order, abi.encode(user, asyncFiller));

    if (zeroForOne) {
      assertEq(currency0.balanceOf(user), userCurrency0Balance - uint256(amount));
      assertEq(currency1.balanceOf(user), userCurrency1Balance);
    } else {
      assertEq(currency1.balanceOf(user), userCurrency1Balance - uint256(amount));
      assertEq(currency0.balanceOf(user), userCurrency0Balance);
    }

    if (zeroForOne) {
      assertEq(manager.balanceOf(address(hook), currency0.toId()), balance0Before + uint256(amount));
    } else {
      assertEq(manager.balanceOf(address(hook), currency1.toId()), balance1Before + uint256(amount));
    }

    assertEq(hook.asyncOrder(poolId, user, zeroForOne), uint256(amount));
  }

}
