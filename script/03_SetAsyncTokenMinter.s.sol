// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {GovernanceAddressResolver} from "./GovernanceAddressResolver.sol";
import {AsyncToken} from "../src/governance/AsyncToken.sol";

contract SetAsyncTokenMinterScript is GovernanceAddressResolver {
    function run() public {
        address timelock = _timelockAddress();
        address asyncToken = _asyncTokenAddress();

        vm.startBroadcast();
        AsyncToken(asyncToken).setMinter(timelock);
        vm.stopBroadcast();
    }
}
