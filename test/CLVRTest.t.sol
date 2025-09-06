// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { CLVR } from "@async-swap/algorithms/clvr.sol";
import { IAlgorithm } from "@async-swap/interfaces/IAlgorithm.sol";
import { BaseAlgorithm } from "@async-swap/algorithms/BaseAlgorithm.sol";

contract CLVRTest is SetupHook {

  CLVR clvrAlgorithm;
  address nonHookAddress = makeAddr("nonHook");

  function setUp() public override {
    super.setUp();
    clvrAlgorithm = new CLVR(address(hook));
  }

  function testCLVRName() public view {
    assertEq(clvrAlgorithm.name(), "CLVR");
  }

  function testCLVRVersion() public view {
    assertEq(clvrAlgorithm.version(), "1.0.0");
  }

  function testCLVRHookAddress() public view {
    assertEq(clvrAlgorithm.HOOKADDRESS(), address(hook));
  }

  function testOrderingRuleFromHook() public {
    vm.prank(address(hook));
    clvrAlgorithm.orderingRule(true, 1000);
  }

  function testOrderingRuleFromHookZeroForOneFalse() public {
    vm.prank(address(hook));
    clvrAlgorithm.orderingRule(false, 2000);
  }

  function testOrderingRuleFromHookVariousAmounts() public {
    vm.startPrank(address(hook));
    clvrAlgorithm.orderingRule(true, 1);
    clvrAlgorithm.orderingRule(false, 999999999);
    clvrAlgorithm.orderingRule(true, 0);
    vm.stopPrank();
  }

  function testOrderingRuleFailsFromNonHook() public {
    vm.prank(nonHookAddress);
    vm.expectRevert("Only hook can call this function");
    clvrAlgorithm.orderingRule(true, 1000);
  }

  function testOrderingRuleFailsFromRandomAddress() public {
    address randomAddr = makeAddr("random");
    vm.prank(randomAddr);
    vm.expectRevert("Only hook can call this function");
    clvrAlgorithm.orderingRule(false, 5000);
  }

  function testFuzzOrderingRule(bool zeroForOne, uint256 amount) public {
    vm.prank(address(hook));
    clvrAlgorithm.orderingRule(zeroForOne, amount);
  }

  function testBaseAlgorithmInheritance() public view {
    assertTrue(clvrAlgorithm.HOOKADDRESS() == address(hook));
  }

}