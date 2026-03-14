// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployGovernanceScript} from "../script/01_DeployGovernance.s.sol";
import {
    WireGovernanceToAsyncSwapScript,
    TransferAsyncTokenMinterToTimelockScript
} from "../script/02_WireGovernance.s.sol";
import {ScriptHelper} from "../script/ScriptHelper.sol";
import {AsyncToken} from "../src/governance/AsyncToken.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract GovernanceScriptTest is Test {
    address internal constant SCRIPT_BROADCASTER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    function test_scriptHelper_builds_expected_broadcast_path() public {
        ScriptHelperHarness harness = new ScriptHelperHarness("");
        string memory root = vm.projectRoot();
        string memory expected =
            string.concat(root, "/broadcast/01_DeployGovernance.s.sol/", vm.toString(block.chainid), "/run-latest.json");
        assertEq(harness.broadcastPath("01_DeployGovernance"), expected);
    }

    function test_deployGovernanceScript_run_deploys_and_configures_contracts() public {
        address deployer = SCRIPT_BROADCASTER;
        vm.deal(deployer, 100 ether);
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));
        vm.setEnv("TIMELOCK_DELAY", "86400");
        vm.setEnv("VOTING_DELAY", "1");
        vm.setEnv("VOTING_PERIOD", "10");
        vm.setEnv("PROPOSAL_THRESHOLD", "100000000000000000000");
        vm.setEnv("QUORUM_PERCENT", "4");

        DeployGovernanceScript script = new DeployGovernanceScript();
        script.run();

        AsyncToken token = script.token();
        TimelockController timelock = script.timelock();

        assertEq(token.minter(), deployer);
        assertEq(timelock.getMinDelay(), 86400);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(script.governor())));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), deployer));
    }

    function test_wireScripts_can_read_previous_outputs() public {
        address deployer = SCRIPT_BROADCASTER;
        vm.deal(deployer, 100 ether);
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));

        vm.startPrank(deployer);
        MockIntentOwned hook = new MockIntentOwned();
        AsyncToken token = new AsyncToken(deployer);
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(1 days, proposers, executors, deployer);
        vm.stopPrank();

        vm.setEnv("TIMELOCK_ADDRESS", vm.toString(address(timelock)));
        vm.setEnv("ASYNCSWAP_ADDRESS", vm.toString(address(hook)));
        vm.setEnv("ASYNC_TOKEN_ADDRESS", vm.toString(address(token)));

        WireGovernanceHarness wire = new WireGovernanceHarness(address(hook), address(timelock), address(token));
        wire.run();
        assertEq(hook.pendingOwner(), address(timelock));

        TransferAsyncTokenMinterHarness minterWire = new TransferAsyncTokenMinterHarness(address(hook), address(timelock), address(token));
        minterWire.run();
        assertEq(token.minter(), address(timelock));
    }
}

contract ScriptHelperHarness is ScriptHelper {
    string internal fixturePath;

    constructor(string memory _fixturePath) {
        fixturePath = _fixturePath;
    }

    function _broadcastPath(string memory) internal view override returns (string memory) {
        if (bytes(fixturePath).length == 0) {
            return super._broadcastPath("01_DeployGovernance");
        }
        return fixturePath;
    }

    function broadcastPath(string memory scriptName) external view returns (string memory) {
        return _broadcastPath(scriptName);
    }

    function readDeployedContractAddress(string memory scriptName, uint256 txIndex) external view returns (address) {
        return _readDeployedContractAddress(scriptName, txIndex);
    }
}

contract WireGovernanceHarness is WireGovernanceToAsyncSwapScript {
    address internal asyncSwapAddr;
    address internal timelockAddr;
    address internal asyncTokenAddr;

    constructor(address _asyncSwapAddr, address _timelockAddr, address _asyncTokenAddr) {
        asyncSwapAddr = _asyncSwapAddr;
        timelockAddr = _timelockAddr;
        asyncTokenAddr = _asyncTokenAddr;
    }

    function _readDeployedContractAddress(string memory scriptName, uint256 txIndex) internal view override returns (address) {
        if (keccak256(bytes(scriptName)) == keccak256(bytes("00_DeployAsyncSwap")) && txIndex == 1) {
            return asyncSwapAddr;
        }
        if (keccak256(bytes(scriptName)) == keccak256(bytes("01_DeployGovernance")) && txIndex == 1) {
            return timelockAddr;
        }
        if (keccak256(bytes(scriptName)) == keccak256(bytes("01_DeployGovernance")) && txIndex == 0) {
            return asyncTokenAddr;
        }
        return address(0);
    }
}

contract TransferAsyncTokenMinterHarness is TransferAsyncTokenMinterToTimelockScript {
    address internal asyncSwapAddr;
    address internal timelockAddr;
    address internal asyncTokenAddr;

    constructor(address _asyncSwapAddr, address _timelockAddr, address _asyncTokenAddr) {
        asyncSwapAddr = _asyncSwapAddr;
        timelockAddr = _timelockAddr;
        asyncTokenAddr = _asyncTokenAddr;
    }

    function _readDeployedContractAddress(string memory scriptName, uint256 txIndex) internal view override returns (address) {
        if (keccak256(bytes(scriptName)) == keccak256(bytes("00_DeployAsyncSwap")) && txIndex == 1) {
            return asyncSwapAddr;
        }
        if (keccak256(bytes(scriptName)) == keccak256(bytes("01_DeployGovernance")) && txIndex == 1) {
            return timelockAddr;
        }
        if (keccak256(bytes(scriptName)) == keccak256(bytes("01_DeployGovernance")) && txIndex == 0) {
            return asyncTokenAddr;
        }
        return address(0);
    }
}

contract MockIntentOwned {
    address public pendingOwner;

    function transferOwnership(address newOwner) external {
        pendingOwner = newOwner;
    }
}
