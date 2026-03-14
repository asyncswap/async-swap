// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {ScriptHelper} from "./ScriptHelper.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {AsyncToken} from "../src/governance/AsyncToken.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract WireGovernanceToAsyncSwapScript is ScriptHelper {
    function run() public {
        address timelock = vm.envOr("TIMELOCK_ADDRESS", _readDeployedContractAddress("01_DeployGovernance", 1));
        address asyncSwap = vm.envOr("ASYNCSWAP_ADDRESS", _readDeployedContractAddress("00_DeployAsyncSwap", 1));

        vm.startBroadcast();
        AsyncSwap(asyncSwap).transferOwnership(timelock);
        vm.stopBroadcast();
    }
}

contract TransferAsyncTokenMinterToTimelockScript is ScriptHelper {
    function run() public {
        address timelock = vm.envOr("TIMELOCK_ADDRESS", _readDeployedContractAddress("01_DeployGovernance", 1));
        address asyncToken = vm.envOr("ASYNC_TOKEN_ADDRESS", _readDeployedContractAddress("01_DeployGovernance", 0));

        vm.startBroadcast();
        AsyncToken(asyncToken).setMinter(timelock);
        vm.stopBroadcast();
    }
}

contract AcceptAsyncSwapOwnershipViaTimelockScript is ScriptHelper {
    function run() public {
        address timelockAddr = vm.envOr("TIMELOCK_ADDRESS", _readDeployedContractAddress("01_DeployGovernance", 1));
        address asyncSwap = vm.envOr("ASYNCSWAP_ADDRESS", _readDeployedContractAddress("00_DeployAsyncSwap", 1));

        TimelockController timelock = TimelockController(payable(timelockAddr));
        bytes memory data = abi.encodeWithSignature("acceptOwnership()");
        bytes32 predecessor = bytes32(0);
        bytes32 salt = bytes32(uint256(0));

        vm.startBroadcast();
        timelock.schedule(asyncSwap, 0, data, predecessor, salt, timelock.getMinDelay());
        vm.stopBroadcast();
    }
}

contract ExecuteAsyncSwapOwnershipAcceptanceScript is ScriptHelper {
    function run() public {
        address timelockAddr = vm.envOr("TIMELOCK_ADDRESS", _readDeployedContractAddress("01_DeployGovernance", 1));
        address asyncSwap = vm.envOr("ASYNCSWAP_ADDRESS", _readDeployedContractAddress("00_DeployAsyncSwap", 1));

        TimelockController timelock = TimelockController(payable(timelockAddr));
        bytes memory data = abi.encodeWithSignature("acceptOwnership()");
        bytes32 predecessor = bytes32(0);
        bytes32 salt = bytes32(uint256(0));

        vm.startBroadcast();
        timelock.execute(asyncSwap, 0, data, predecessor, salt);
        vm.stopBroadcast();
    }
}

contract RevokeBootstrapTimelockRolesScript is ScriptHelper {
    function run() public {
        address timelockAddr = vm.envOr("TIMELOCK_ADDRESS", _readDeployedContractAddress("01_DeployGovernance", 1));
        address governor = vm.envOr("GOVERNOR_ADDRESS", _readDeployedContractAddress("01_DeployGovernance", 2));
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        TimelockController timelock = TimelockController(payable(timelockAddr));

        vm.startBroadcast();
        timelock.grantRole(timelock.PROPOSER_ROLE(), governor);
        timelock.revokeRole(timelock.PROPOSER_ROLE(), deployer);
        timelock.revokeRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopBroadcast();
    }
}
