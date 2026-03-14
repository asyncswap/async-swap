// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {ScriptHelper} from "./ScriptHelper.sol";
import {AsyncToken} from "../src/governance/AsyncToken.sol";
import {AsyncGovernor} from "../src/governance/AsyncGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract DeployGovernanceScript is ScriptHelper {
    AsyncToken public token;
    TimelockController public timelock;
    AsyncGovernor public governor;

    function run() public {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 timelockDelay = vm.envUint("TIMELOCK_DELAY");
        uint48 votingDelay = uint48(vm.envUint("VOTING_DELAY"));
        uint32 votingPeriod = uint32(vm.envUint("VOTING_PERIOD"));
        uint256 proposalThreshold = vm.envUint("PROPOSAL_THRESHOLD");
        uint256 quorumPercent = vm.envUint("QUORUM_PERCENT");

        vm.startBroadcast();

        token = new AsyncToken(deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(timelockDelay, proposers, executors, deployer);

        governor = new AsyncGovernor(token, timelock, votingDelay, votingPeriod, proposalThreshold, quorumPercent);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));

        vm.stopBroadcast();
    }
}
