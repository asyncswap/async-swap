// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { Currency } from "v4-core/types/Currency.sol";

contract WithdralTest is SetupHook {

  address user;
  address user2;

  function setUp() public override {
    super.setUp();
    user = makeAddr("user");
    user2 = makeAddr("user2");
    topUp(user, 1 ether);
    topUp(user2, 2 ether);
  }

  function testFuzz_withdraw(bool zeroForOne, uint256 amountIn) public {
    amountIn = bound(amountIn, 1, 1 ether);
    Currency specified = zeroForOne ? key.currency0 : key.currency1;

    AsyncOrder memory order = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user,
      zeroForOne: zeroForOne,
      amountIn: amountIn,
      sqrtPrice: 2 ** 96
    });

    vm.startPrank(user);
    _makeOrder(user, order);

    uint256 balanceBefore = specified.balanceOf(user);
    router.withdraw(key, zeroForOne, amountIn);
    vm.stopPrank();

    assertEq(specified.balanceOf(user), balanceBefore + amountIn);
  }

  function _makeOrder(address _user, AsyncOrder memory order) internal {
    if (order.zeroForOne) {
      token0.approve(address(router), order.amountIn);
    } else {
      token1.approve(address(router), order.amountIn);
    }
    router.swap(order, abi.encode(_user, address(router)));
  }

}
