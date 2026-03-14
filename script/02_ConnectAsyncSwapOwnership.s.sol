// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {GovernanceAddressResolver} from "./GovernanceAddressResolver.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";

contract ConnectGovernanceToAsyncSwapScript is GovernanceAddressResolver {
    function run() public {
        address timelock = _timelockAddress();
        address asyncSwap = _asyncSwapAddress();

        vm.startBroadcast();
        AsyncSwap(asyncSwap).transferOwnership(timelock);
        vm.stopBroadcast();
    }
}
