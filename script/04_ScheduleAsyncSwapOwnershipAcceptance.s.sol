// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {GovernanceAddressResolver} from "./GovernanceAddressResolver.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract ScheduleAsyncSwapOwnershipAcceptanceScript is GovernanceAddressResolver {
    function run() public {
        address timelockAddr = _timelockAddress();
        address asyncSwap = _asyncSwapAddress();

        TimelockController timelock = TimelockController(payable(timelockAddr));
        bytes memory data = _acceptOwnershipCalldata();
        bytes32 predecessor = bytes32(0);
        bytes32 salt = bytes32(uint256(0));

        vm.startBroadcast();
        timelock.schedule(asyncSwap, 0, data, predecessor, salt, timelock.getMinDelay());
        vm.stopBroadcast();
    }
}
