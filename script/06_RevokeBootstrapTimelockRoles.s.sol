// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {GovernanceAddressResolver} from "./GovernanceAddressResolver.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract RevokeBootstrapTimelockRolesScript is GovernanceAddressResolver {
    function run() public {
        address timelockAddr = _timelockAddress();
        address governor = _governorAddress();
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        TimelockController timelock = TimelockController(payable(timelockAddr));

        vm.startBroadcast();
        timelock.grantRole(timelock.PROPOSER_ROLE(), governor);
        timelock.revokeRole(timelock.PROPOSER_ROLE(), deployer);
        timelock.revokeRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopBroadcast();
    }
}
