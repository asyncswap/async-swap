// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";

contract CounterTest is Test {
    IPoolManager manager;
    AsyncSwap public asyncswap;
    address owner = makeAddr("owner");

    function setUp() public {
        manager = new PoolManager(owner);
        asyncswap = new AsyncSwap(manager);
    }
}
