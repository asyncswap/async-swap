// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";

contract CounterScript is Script {
    AsyncSwap public counter;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        PoolManager pm = new PoolManager(msg.sender);
        counter = new AsyncSwap(pm);

        vm.stopBroadcast();
    }
}
