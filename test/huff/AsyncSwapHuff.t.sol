// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { Test, console } from "forge-std/Test.sol";
import { HuffNeoDeployer } from "foundry-huff-neo/HuffNeoDeployer.sol";
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { BeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

interface IAsyncSwap {

  function beforeAddLiquidity(
    address sender,
    PoolKey calldata key,
    IPoolManager.ModifyLiquidityParams calldata params,
    bytes calldata hookData
  ) external returns (bytes4);
  function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);
  function beforeSwap(
    address sender,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    bytes calldata hookData
  ) external returns (bytes4, BeforeSwapDelta, uint24);
  function poolManager() external returns (address);
  function getHookPermissions() external returns (Hooks.Permissions memory);

}

contract TestAsyncSwapHuff is Test {

  address owner = makeAddr("owner");
  PoolManager poolManager = new PoolManager(owner);
  IAsyncSwap hook;

  error RequireError(string);

  function setUp() public {
    vm.skip(true);
    bytes memory args = abi.encode(poolManager);
    address hookFlags = address(
      uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
          | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
      )
    );
    bytes memory creationCode = HuffNeoDeployer.config().with_args(args).creation_code_with_args("src/AsyncSwap.huff");
    vm.etch(hookFlags, abi.encodePacked(creationCode));
    (bool success, bytes memory runtimeBytecode) = hookFlags.call("");
    require(success, "Failed to create runtime bytecode.");
    vm.etch(hookFlags, runtimeBytecode);
    hook = IAsyncSwap(hookFlags);
  }

  function test_PoolManager() public {
    vm.skip(true);
    assertEq(hook.poolManager(), address(poolManager));
  }

  function test_GetHookPermissions() public {
    vm.skip(true);
    Hooks.Permissions memory hookFlags = hook.getHookPermissions();
    console.logBytes(abi.encode(hookFlags));
    Hooks.Permissions memory expectedFlags = Hooks.Permissions({
      beforeInitialize: true,
      afterInitialize: false,
      beforeAddLiquidity: true,
      afterAddLiquidity: false,
      beforeRemoveLiquidity: false,
      afterRemoveLiquidity: false,
      beforeSwap: true,
      afterSwap: false,
      beforeDonate: false,
      afterDonate: false,
      beforeSwapReturnDelta: true,
      afterSwapReturnDelta: false,
      afterAddLiquidityReturnDelta: false,
      afterRemoveLiquidityReturnDelta: false
    });
    assertEq(abi.encode(hookFlags), abi.encode(expectedFlags));
  }

  function test_FuzzBeforeSwapCaller(
    address caller,
    address s,
    PoolKey calldata k,
    IPoolManager.SwapParams calldata p,
    bytes calldata h
  ) public {
    vm.skip(true);
    vm.assume(caller != address(poolManager));
    vm.startPrank(caller);
    vm.expectRevert("NOT POOL MANAGER!");
    hook.beforeSwap(s, k, p, h);
    vm.stopPrank();
  }

  function test_beforeFuzzInitializeCaller(address caller, address s, PoolKey calldata k, uint160 sp) public {
    vm.skip(true);
    vm.assume(caller != address(poolManager));
    vm.startPrank(caller);
    vm.expectRevert("NOT POOL MANAGER!");
    hook.beforeInitialize(s, k, sp);
    vm.stopPrank();
  }

}
