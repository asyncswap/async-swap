// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { Currency } from "v4-core/interfaces/IPoolManager.sol";
import { CurrencyLibrary } from "v4-core/types/Currency.sol";

/// @title Slippage Protection Test
/// @notice Tests to verify that slippage protection works correctly
contract SlippageProtectionTest is SetupHook {

  using CurrencyLibrary for Currency;

  address user;
  address filler;

  function setUp() public override {
    super.setUp();
    user = makeAddr("user");
    filler = makeAddr("filler");
    topUp(user, 1000 ether);
    topUp(filler, 1000 ether);
  }

  /// @notice Test that filler can provide different amountOut
  function testFillerProvidesCustomAmount() public {
    uint256 userDeposit = 1 ether;
    uint256 fillerOffer = 0.95 ether; // Filler offers less

    // User creates order: deposits 1, wants at least 0.9
    AsyncOrder memory order = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user,
      zeroForOne: true,
      amountIn: userDeposit,
      minAmountOut: 0.9 ether, // User willing to accept 0.9 minimum
      maxAmountIn: 0, // Not used in this case
      sqrtPrice: 2 ** 96
    });

    // User swaps
    vm.startPrank(user);
    token0.approve(address(manager), userDeposit);
    token0.approve(address(router), userDeposit);
    router.swap(order, abi.encode(user, address(router)));
    vm.stopPrank();

    // Verify order was created
    assertEq(hook.asyncOrderAmount(poolId, user, true), userDeposit);

    uint256 userBalance1Before = token1.balanceOf(user);
    uint256 fillerBalance0Before = manager.balanceOf(filler, currency0.toId());

    // Filler fills with 0.95 tokens (within acceptable range)
    vm.startPrank(filler);
    token1.approve(address(manager), fillerOffer);
    token1.approve(address(router), fillerOffer);
    router.fillOrder(order, abi.encode(fillerOffer));
    vm.stopPrank();

    // Verify: User receives 0.95 token1 (what filler offered)
    uint256 userBalance1After = token1.balanceOf(user);
    assertEq(userBalance1After - userBalance1Before, fillerOffer, "User should receive filler's offer");

    // Verify: Filler receives 1 token0 (user's deposit) as ERC-6909 claims in PoolManager
    uint256 fillerBalance0After = manager.balanceOf(filler, currency0.toId());
    assertEq(fillerBalance0After - fillerBalance0Before, userDeposit, "Filler should receive user's deposit");
  }

  /// @notice Test that order reverts if amountOut < minAmountOut
  function testSlippageProtectionMinAmountOut() public {
    uint256 userDeposit = 100 ether;
    uint256 fillerOffer = 85 ether; // Too low!

    AsyncOrder memory order = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user,
      zeroForOne: true,
      amountIn: userDeposit,
      minAmountOut: 90 ether, // User requires at least 90
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    // User swaps
    vm.startPrank(user);
    token0.approve(address(router), userDeposit);
    router.swap(order, abi.encode(user, address(router)));
    vm.stopPrank();

    // Filler tries to fill with 85 tokens (below minimum)
    vm.startPrank(filler);
    token1.approve(address(router), fillerOffer);
    vm.expectRevert(); // Should revert with SlippageExceeded
    router.fillOrder(order, abi.encode(fillerOffer));
    vm.stopPrank();
  }

  /// @notice Test that order reverts if amountOut > maxAmountIn
  function testSlippageProtectionMaxAmountIn() public {
    uint256 userDeposit = 100 ether;
    uint256 fillerOffer = 110 ether; // Too high!

    AsyncOrder memory order = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user,
      zeroForOne: true,
      amountIn: userDeposit,
      minAmountOut: 0,
      maxAmountIn: 105 ether, // User willing to accept max 105
      sqrtPrice: 2 ** 96
    });

    // User swaps
    vm.startPrank(user);
    token0.approve(address(router), userDeposit);
    router.swap(order, abi.encode(user, address(router)));
    vm.stopPrank();

    // Filler tries to fill with 110 tokens (above maximum)
    vm.startPrank(filler);
    token1.approve(address(router), fillerOffer);
    vm.expectRevert(); // Should revert with MaxAmountExceeded
    router.fillOrder(order, abi.encode(fillerOffer));
    vm.stopPrank();
  }

  /// @notice Test that slippage protection can be disabled (0 values)
  function testSlippageProtectionDisabled() public {
    uint256 userDeposit = 100 ether;
    uint256 fillerOffer = 50 ether; // Very unfavorable rate

    AsyncOrder memory order = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user,
      zeroForOne: true,
      amountIn: userDeposit,
      minAmountOut: 0, // No minimum (disabled)
      maxAmountIn: 0, // No maximum (disabled)
      sqrtPrice: 2 ** 96
    });

    // User swaps
    vm.startPrank(user);
    token0.approve(address(router), userDeposit);
    router.swap(order, abi.encode(user, address(router)));
    vm.stopPrank();

    uint256 userBalance1Before = token1.balanceOf(user);

    // Filler fills with 50 tokens (bad rate but allowed since protection disabled)
    vm.startPrank(filler);
    token1.approve(address(router), fillerOffer);
    router.fillOrder(order, abi.encode(fillerOffer));
    vm.stopPrank();

    // Verify: Order executes even with unfavorable rate
    uint256 userBalance1After = token1.balanceOf(user);
    assertEq(userBalance1After - userBalance1Before, fillerOffer, "Order should execute when protection disabled");
  }

  /// @notice Test competitive filling: best rate wins
  function testCompetitiveFillingBestRate() public {
    uint256 userDeposit = 100 ether;

    AsyncOrder memory order = AsyncOrder({
      deadline: block.timestamp + 1 hours,
      key: key,
      owner: user,
      zeroForOne: true,
      amountIn: userDeposit,
      minAmountOut: 95 ether, // User wants at least 95
      maxAmountIn: 0,
      sqrtPrice: 2 ** 96
    });

    // User swaps
    vm.startPrank(user);
    token0.approve(address(router), userDeposit);
    router.swap(order, abi.encode(user, address(router)));
    vm.stopPrank();

    uint256 userBalance1Before = token1.balanceOf(user);

    // Filler1 offers 98 tokens (good rate)
    address filler1 = makeAddr("filler1");
    topUp(filler1, 100 ether);
    vm.startPrank(filler1);
    token1.approve(address(router), 98 ether);
    router.fillOrder(order, abi.encode(98 ether));
    vm.stopPrank();

    // Verify: User gets 98 tokens
    uint256 userBalance1After = token1.balanceOf(user);
    assertEq(userBalance1After - userBalance1Before, 98 ether, "User should receive best offer");

    // Order is now filled, filler2 cannot fill
    address filler2 = makeAddr("filler2");
    topUp(filler2, 100 ether);
    vm.startPrank(filler2);
    token1.approve(address(router), 99 ether);
    vm.expectRevert(); // Already filled
    router.fillOrder(order, abi.encode(99 ether));
    vm.stopPrank();
  }

}
