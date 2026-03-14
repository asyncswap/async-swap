// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {GovernanceAddressResolver} from "./GovernanceAddressResolver.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";

contract TransferAsyncSwapOwnershipScript is GovernanceAddressResolver {
    function run() public {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address timelock = _timelockAddress();
        address asyncSwap = _asyncSwapAddress();

        vm.startBroadcast(deployer);
        AsyncSwap(asyncSwap).transferOwnership(timelock);
        vm.stopBroadcast();
    }
}
