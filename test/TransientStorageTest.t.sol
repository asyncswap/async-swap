// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { TransientStorage } from "@async-swap/utils/TransientStorage.sol";
import { Test } from "forge-std/Test.sol";

contract TestTransientStorage is TransientStorage {

  function testTstore(bytes32 key, bytes32 value) external {
    tstore(key, value);
  }

  function testTload(bytes32 key) external view returns (bytes32) {
    return tload(key);
  }

}

contract TransientStorageTest is Test {

  TestTransientStorage internal transientStorage;

  function setUp() public {
    transientStorage = new TestTransientStorage();
  }

  function testStoreAndLoadSingleValue() public {
    bytes32 key = keccak256("test_key");
    bytes32 value = keccak256("test_value");

    transientStorage.testTstore(key, value);
    bytes32 loaded = transientStorage.testTload(key);

    assertEq(loaded, value);
  }

  function testStoreAndLoadZeroValue() public {
    bytes32 key = keccak256("zero_key");
    bytes32 value = bytes32(0);

    transientStorage.testTstore(key, value);
    bytes32 loaded = transientStorage.testTload(key);

    assertEq(loaded, value);
  }

  function testOverwriteValue() public {
    bytes32 key = keccak256("overwrite_key");
    bytes32 value1 = keccak256("value1");
    bytes32 value2 = keccak256("value2");

    transientStorage.testTstore(key, value1);
    transientStorage.testTstore(key, value2);
    bytes32 loaded = transientStorage.testTload(key);

    assertEq(loaded, value2);
  }

  function testLoadUnsetKey() public view {
    bytes32 key = keccak256("unset_key");
    bytes32 loaded = transientStorage.testTload(key);

    assertEq(loaded, bytes32(0));
  }

  function testFuzzStoreAndLoad(bytes32 key, bytes32 value) public {
    transientStorage.testTstore(key, value);
    bytes32 loaded = transientStorage.testTload(key);

    assertEq(loaded, value);
  }

  function testMultipleKeysAndValues() public {
    bytes32 key1 = keccak256("key1");
    bytes32 key2 = keccak256("key2");
    bytes32 value1 = keccak256("value1");
    bytes32 value2 = keccak256("value2");

    transientStorage.testTstore(key1, value1);
    transientStorage.testTstore(key2, value2);

    assertEq(transientStorage.testTload(key1), value1);
    assertEq(transientStorage.testTload(key2), value2);
  }

}
