// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { IAlgorithm } from "@async-swap/interfaces/IAlgorithm.sol";
import { console } from "forge-std/Test.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";

contract AsyncswapStateTest is SetupHook {

  function setUp() public override {
    super.setUp();
  }

  function testStateAlgorithm() public view {
    (IPoolManager pm, IAlgorithm a) = hook.asyncOrders(poolId);
    assertEq(address(pm), address(manager));
    assertNotEq(address(a), address(0x00));
  }

}
