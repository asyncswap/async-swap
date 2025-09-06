// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { IAlgorithm } from "@async-swap/interfaces/IAlgorithm.sol";

contract CLVRHookTest is SetupHook {

  IAlgorithm algorithm;

  function setUp() public override {
    super.setUp();
    algorithm = hook.ALGORITHM();
  }

  /// this should test the intialized algoritm was selected
  function testCheckSetAlgorithm() public { }

  function testExecuteOrderBuy() public {
    // Test setup for a buy order
    bool zeroForOne = true;
    uint256 amount = 1000;

    // Execute the order
    vm.prank(address(hook));
    algorithm.orderingRule(zeroForOne, amount);

    // Add assertions to verify the expected state changes
    // Example: assertEq(expected, actual, "Error message");
  }

  function testExecuteOrderSell() public {
    // Test setup for a sell order
    bool zeroForOne = false;
    uint256 amount = 1000;

    // Execute the order
    vm.prank(address(hook));
    algorithm.orderingRule(zeroForOne, amount);

    // Add assertions to verify the expected state changes
    // Example: assertEq(expected, actual, "Error message");
  }

  function testAlogorithmHasName() public view {
    vm.assumeNoRevert();
    algorithm.name();
  }

  function testAlogorithmHasVersion() public view {
    vm.assumeNoRevert();
    algorithm.version();
  }

}
