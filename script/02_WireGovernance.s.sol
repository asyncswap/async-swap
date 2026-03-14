// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {ScriptHelper} from "./ScriptHelper.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {AsyncToken} from "../src/governance/AsyncToken.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

abstract contract GovernanceAddressResolver is ScriptHelper {
    function _timelockAddress() internal view returns (address) {
        return vm.envOr("TIMELOCK_ADDRESS", _readDeployedContractAddress("01_DeployGovernance", 1));
    }

    function _asyncSwapAddress() internal view returns (address) {
        return vm.envOr("ASYNCSWAP_ADDRESS", _readDeployedContractAddress("00_DeployAsyncSwap", 1));
    }

    function _asyncTokenAddress() internal view returns (address) {
        return vm.envOr("ASYNC_TOKEN_ADDRESS", _readDeployedContractAddress("01_DeployGovernance", 0));
    }

    function _governorAddress() internal view returns (address) {
        return vm.envOr("GOVERNOR_ADDRESS", _readDeployedContractAddress("01_DeployGovernance", 2));
    }

    function _acceptOwnershipCalldata() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("acceptOwnership()");
    }
}

contract WireGovernanceToAsyncSwapScript is GovernanceAddressResolver {
    function run() public {
        address timelock = _timelockAddress();
        address asyncSwap = _asyncSwapAddress();

        vm.startBroadcast();
        AsyncSwap(asyncSwap).transferOwnership(timelock);
        vm.stopBroadcast();
    }
}

contract TransferAsyncTokenMinterToTimelockScript is GovernanceAddressResolver {
    function run() public {
        address timelock = _timelockAddress();
        address asyncToken = _asyncTokenAddress();

        vm.startBroadcast();
        AsyncToken(asyncToken).setMinter(timelock);
        vm.stopBroadcast();
    }
}

contract AcceptAsyncSwapOwnershipViaTimelockScript is GovernanceAddressResolver {
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

contract ExecuteAsyncSwapOwnershipAcceptanceScript is GovernanceAddressResolver {
    function run() public {
        address timelockAddr = _timelockAddress();
        address asyncSwap = _asyncSwapAddress();

        TimelockController timelock = TimelockController(payable(timelockAddr));
        bytes memory data = _acceptOwnershipCalldata();
        bytes32 predecessor = bytes32(0);
        bytes32 salt = bytes32(uint256(0));

        vm.startBroadcast();
        timelock.execute(asyncSwap, 0, data, predecessor, salt);
        vm.stopBroadcast();
    }
}

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
