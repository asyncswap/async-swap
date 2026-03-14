// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {GovernanceAddressResolver} from "./GovernanceAddressResolver.sol";
import {AsyncToken} from "../src/governance/AsyncToken.sol";

contract SetAsyncTokenMinterScript is GovernanceAddressResolver {
    function run() public {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address timelock = _timelockAddress();
        address asyncToken = _asyncTokenAddress();

        vm.startBroadcast(deployer);
        AsyncToken(asyncToken).setMinter(timelock);
        vm.stopBroadcast();
    }
}
