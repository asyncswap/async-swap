// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";

contract CounterScript is Script {
    AsyncSwap public counter;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        counter = new AsyncSwap();

        vm.stopBroadcast();
    }
}
