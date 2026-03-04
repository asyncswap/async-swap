// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { Currency } from "v4-core/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";
import { CurrencyLibrary } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @title Ether Test contract
contract EtherTest is SetupHook {

  using CurrencyLibrary for Currency;

  address alice = makeAddr("alice");
  address bob = makeAddr("bob");

  function setUp() public override {
    super.setUp();
    // Override the default setup to use Ether
    deployEtherPool();
    topUp(alice, 50 ether);
    topUp(bob, 50 ether);
    vm.deal(alice, 50 ether);
    vm.deal(bob, 50 ether);
  }

  function deployEtherPool() public {
    vm.startPrank(owner);
    address tokenB = address(new MockERC20("TEST Token 2", "TST2", 18));
    currency1 = Currency.wrap(address(tokenB));
    vm.stopPrank();

    token1 = MockERC20(Currency.unwrap(currency1));
    currency0 = Currency.wrap(address(0)); // Ether

    vm.label(address(token1), "token1");
    vm.label(address(0), "Ether");

    // Create pool key with Ether as currency0
    key = PoolKey({
      currency0: currency0,
      currency1: currency1,
      fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
      tickSpacing: int24(60),
      hooks: hook
    });
    poolId = key.toId();

    // Initialize the pool
    manager.initialize(key, 2 ** 96);

    // Mint token1 to owner
    token1.mint(owner, 2 ** 128 - 1);
  }

  function testInitializeEtherPool() public view {
    assertEq(Currency.unwrap(key.currency0), address(0));
    assertEq(Currency.unwrap(key.currency1), address(token1));
  }

  function testFuzz_EtherSwapOrder(uint256 swapAmount, bool zeroForOne) public {
    swapAmount = bound(swapAmount, 1, 50 ether);

    uint256 token0Before = alice.balance;
    uint256 token1Before = token1.balanceOf(alice);

    // Alice creates async swap order: Ether -> token1
    vm.startPrank(alice);
    AsyncOrder memory aliceOrder = AsyncOrder({
      key: key,
      owner: alice,
      zeroForOne: zeroForOne,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96,
      deadline: block.timestamp + 1 hours
    });
    if (zeroForOne) {
      router.swap{ value: swapAmount }(aliceOrder, abi.encode(alice, address(router)));
    } else {
      token1.approve(address(router), swapAmount);
      router.swap(aliceOrder, abi.encode(alice, address(router)));
    }
    vm.stopPrank();

    // Verify Alice's order
    assertEq(hook.asyncOrderAmount(poolId, alice, zeroForOne), swapAmount);
    assertTrue(hook.isExecutor(poolId, alice, address(router)));

    // Check Alice's Ether balance decreased
    if (zeroForOne) {
      assertEq(alice.balance, token0Before - swapAmount);
    } else {
      assertEq(token1.balanceOf(alice), token1Before - swapAmount);
    }
  }

  function testEtherOrderFill() public {
    uint256 swapAmount = 1 ether;

    // Alice creates order
    vm.startPrank(alice);
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

    router.swap{ value: swapAmount }(aliceOrder, abi.encode(alice, address(router)));
    vm.stopPrank();
    assertEq(manager.balanceOf(address(hook), currency0.toId()), 1 ether);

    // Record alice's token1 balance before fill
    uint256 aliceToken1Before = token1.balanceOf(alice);

    // Bob fills Alice's order with token1
    vm.startPrank(bob);
    token1.approve(address(router), swapAmount);
    router.fillOrder(aliceOrder, abi.encode(aliceOrder.amountIn));
    vm.stopPrank();

    // Verify order completion
    assertEq(hook.asyncOrderAmount(poolId, alice, true), 0);

    // Alice receives token1 as ERC20 (delta), bob receives ETH as ERC-6909 claims
    assertEq(token1.balanceOf(alice) - aliceToken1Before, swapAmount);
    assertEq(manager.balanceOf(bob, currency0.toId()), swapAmount);
  }

  function testEtherWithdrawal() public {
    uint256 swapAmount = 1 ether;

    // Alice creates order
    vm.startPrank(alice);
    AsyncOrder memory aliceOrder = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: alice,
      zeroForOne: true,
      amountIn: swapAmount,
      minAmountOut: 0,
      maxAmountIn: 0,
      sqrtPrice: 4295128740
    });

    router.swap{ value: swapAmount }(aliceOrder, abi.encode(alice, address(router)));
    vm.stopPrank();

    // Alice withdraws her Ether order
    uint256 balanceBefore = alice.balance;
    vm.prank(alice);
    router.withdraw(key, true, swapAmount);

    // Verify withdrawal
    assertEq(alice.balance, balanceBefore + swapAmount);
    assertEq(hook.asyncOrderAmount(poolId, alice, true), 0);
  }

}
