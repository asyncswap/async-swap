// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SetupHook } from "./SetupHook.t.sol";
import { BaseAlgorithm } from "@async-swap/algorithms/BaseAlgorithm.sol";
import { IAlgorithm } from "@async-swap/interfaces/IAlgorithm.sol";

// Mock implementation for testing BaseAlgorithm
contract MockAlgorithm is BaseAlgorithm {
  
  constructor(address _hookAddress) BaseAlgorithm(_hookAddress) {}

  function name() external pure override returns (string memory) {
    return "MockAlgorithm";
  }

  function version() external pure override returns (string memory) {
    return "1.0.0";
  }

  function orderingRule(bool zeroForOne, uint256 amount) external override onlyHook {
    // Mock implementation - just emit an event or do nothing
    // This allows us to test the BaseAlgorithm functionality
  }
}

contract BaseAlgorithmTest is SetupHook {

  MockAlgorithm mockAlgorithm;
  address nonHookAddress = makeAddr("nonHook");

  function setUp() public override {
    super.setUp();
    mockAlgorithm = new MockAlgorithm(address(hook));
  }

  function testConstructorSetsHookAddress() public view {
    assertEq(mockAlgorithm.HOOKADDRESS(), address(hook));
  }

  function testConstructorWithZeroAddress() public {
    MockAlgorithm zeroHookAlgorithm = new MockAlgorithm(address(0));
    assertEq(zeroHookAlgorithm.HOOKADDRESS(), address(0));
  }

  function testOnlyHookModifierAllowsHook() public {
    vm.prank(address(hook));
    mockAlgorithm.orderingRule(true, 1000);
    // Should not revert
  }

  function testOnlyHookModifierBlocksNonHook() public {
    vm.prank(nonHookAddress);
    vm.expectRevert("Only hook can call this function");
    mockAlgorithm.orderingRule(true, 1000);
  }

  function testOnlyHookModifierBlocksRandomAddress() public {
    address randomAddr = makeAddr("random");
    vm.prank(randomAddr);
    vm.expectRevert("Only hook can call this function");
    mockAlgorithm.orderingRule(false, 5000);
  }

  function testNameFunction() public view {
    assertEq(mockAlgorithm.name(), "MockAlgorithm");
  }

  function testVersionFunction() public view {
    assertEq(mockAlgorithm.version(), "1.0.0");
  }

  function testHookAddressGetter() public view {
    assertEq(mockAlgorithm.HOOKADDRESS(), address(hook));
  }

  function testMultipleCallsFromHook() public {
    vm.startPrank(address(hook));
    mockAlgorithm.orderingRule(true, 100);
    mockAlgorithm.orderingRule(false, 200);
    mockAlgorithm.orderingRule(true, 300);
    vm.stopPrank();
    // All should succeed
  }

  function testFuzzOrderingRuleFromHook(bool zeroForOne, uint256 amount) public {
    vm.prank(address(hook));
    mockAlgorithm.orderingRule(zeroForOne, amount);
    // Should not revert regardless of parameters when called from hook
  }

  function testFuzzOrderingRuleFromNonHook(bool zeroForOne, uint256 amount, address caller) public {
    vm.assume(caller != address(hook));
    vm.prank(caller);
    vm.expectRevert("Only hook can call this function");
    mockAlgorithm.orderingRule(zeroForOne, amount);
  }

}

// Test contract for BaseAlgorithm without overrides
contract UnimplementedAlgorithm is BaseAlgorithm {
  
  constructor(address _hookAddress) BaseAlgorithm(_hookAddress) {}
  
  // Don't override the virtual functions to test base revert behavior
}

contract BaseAlgorithmUnimplementedTest is SetupHook {
  
  UnimplementedAlgorithm unimplementedAlgorithm;
  
  function setUp() public override {
    super.setUp();
    unimplementedAlgorithm = new UnimplementedAlgorithm(address(hook));
  }
  
  function testNameNotImplemented() public {
    vm.expectRevert("BaseAlgorithm: Not implemented");
    unimplementedAlgorithm.name();
  }
  
  function testVersionNotImplemented() public {
    vm.expectRevert("BaseAlgorithm: Not implemented");
    unimplementedAlgorithm.version();
  }
  
  function testOrderingRuleNotImplemented() public {
    vm.prank(address(hook));
    vm.expectRevert("BaseAlgorithm: Ordering rule not implemented!");
    unimplementedAlgorithm.orderingRule(true, 1000);
  }
  

}