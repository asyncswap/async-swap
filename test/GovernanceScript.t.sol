// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployGovernanceScript} from "../script/01_DeployGovernance.s.sol";
import {TransferAsyncSwapOwnershipScript} from "../script/02_TransferAsyncSwapOwnership.s.sol";
import {SetAsyncTokenMinterScript} from "../script/03_SetAsyncTokenMinter.s.sol";
import {ScheduleAsyncSwapOwnershipAcceptanceScript} from "../script/04_ScheduleAsyncSwapOwnershipAcceptance.s.sol";
import {ExecuteAsyncSwapOwnershipAcceptanceScript} from "../script/05_ExecuteAsyncSwapOwnershipAcceptance.s.sol";
import {RevokeBootstrapTimelockRolesScript} from "../script/06_RevokeBootstrapTimelockRoles.s.sol";
import {ScriptHelper} from "../script/ScriptHelper.sol";
import {AsyncToken} from "../src/governance/AsyncToken.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract GovernanceScriptTest is Test {
    address internal constant SCRIPT_BROADCASTER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    function test_scriptHelper_builds_expected_broadcast_path() public {
        vm.setEnv("CHAIN", "anvil");
        vm.setEnv("RUN_MODE", "broadcast");
        ScriptHelperHarness harness = new ScriptHelperHarness("");
        string memory root = vm.projectRoot();
        string memory expected = string.concat(
            root, "/broadcast/01_DeployGovernance.s.sol/", vm.toString(block.chainid), "/run-latest.json"
        );
        assertEq(harness.broadcastPath("01_DeployGovernance"), expected);
    }

    function test_scriptHelper_named_getters_read_env() public {
        ScriptHelperHarness harness = new ScriptHelperHarness("");
        vm.setEnv("ASYNCSWAP_ADDRESS", vm.toString(address(0x1111)));
        vm.setEnv("ASYNC_TOKEN_ADDRESS", vm.toString(address(0x2222)));
        vm.setEnv("TIMELOCK_ADDRESS", vm.toString(address(0x3333)));
        vm.setEnv("GOVERNOR_ADDRESS", vm.toString(address(0x4444)));

        assertEq(harness.deployedAsyncSwap(), address(0x1111));
        assertEq(harness.deployedAsyncToken(), address(0x2222));
        assertEq(harness.deployedTimelock(), address(0x3333));
        assertEq(harness.deployedGovernor(), address(0x4444));
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
        MockMintAdmin token = new MockMintAdmin();
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(1 days, proposers, executors, deployer);
        vm.stopPrank();

        vm.setEnv("TIMELOCK_ADDRESS", vm.toString(address(timelock)));
        vm.setEnv("ASYNCSWAP_ADDRESS", vm.toString(address(hook)));
        vm.setEnv("ASYNC_TOKEN_ADDRESS", vm.toString(address(token)));

        TransferAsyncSwapOwnershipHarness wire =
            new TransferAsyncSwapOwnershipHarness(address(hook), address(timelock), address(token));
        wire.run();
        assertEq(hook.pendingOwner(), address(timelock));

        SetAsyncTokenMinterHarness minterWire =
            new SetAsyncTokenMinterHarness(address(hook), address(timelock), address(token));
        minterWire.run();
        assertEq(token.minter(), address(timelock));
    }

    function test_schedule_and_execute_acceptOwnership_scripts_work() public {
        address deployer = SCRIPT_BROADCASTER;
        vm.deal(deployer, 100 ether);
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));

        vm.startPrank(deployer);
        MockIntentOwned hook = new MockIntentOwned();
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(1 days, proposers, executors, deployer);
        vm.stopPrank();

        vm.prank(deployer);
        hook.transferOwnership(address(timelock));

        vm.setEnv("TIMELOCK_ADDRESS", vm.toString(address(timelock)));
        vm.setEnv("ASYNCSWAP_ADDRESS", vm.toString(address(hook)));

        ScheduleOwnershipHarness schedule = new ScheduleOwnershipHarness(address(hook), address(timelock));
        schedule.run();

        bytes32 opId = timelock.hashOperation(
            address(hook), 0, abi.encodeWithSignature("acceptOwnership()"), bytes32(0), bytes32(0)
        );
        assertTrue(timelock.isOperationPending(opId) || timelock.isOperationReady(opId));

        vm.warp(block.timestamp + 1 days + 1);
        ExecuteOwnershipHarness execute = new ExecuteOwnershipHarness(address(hook), address(timelock));
        execute.run();

        assertEq(hook.protocolOwner(), address(timelock));
    }

    function test_revokeBootstrapRoles_script_revokes_deployer_roles() public {
        address deployer = SCRIPT_BROADCASTER;
        address governor = address(0x4444);
        vm.deal(deployer, 100 ether);
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));
        vm.setEnv("GOVERNOR_ADDRESS", vm.toString(governor));

        vm.startPrank(deployer);
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(1 days, proposers, executors, deployer);
        vm.stopPrank();

        vm.setEnv("TIMELOCK_ADDRESS", vm.toString(address(timelock)));

        RevokeBootstrapHarness revoke = new RevokeBootstrapHarness(address(timelock), governor);
        revoke.run();

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), governor));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
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

    function deployedAsyncSwap() external view returns (address) {
        return _deployedAsyncSwap();
    }

    function deployedAsyncToken() external view returns (address) {
        return _deployedAsyncToken();
    }

    function deployedTimelock() external view returns (address) {
        return _deployedTimelock();
    }

    function deployedGovernor() external view returns (address) {
        return _deployedGovernor();
    }
}

contract TransferAsyncSwapOwnershipHarness is TransferAsyncSwapOwnershipScript {
    address internal asyncSwapAddr;
    address internal timelockAddr;
    address internal asyncTokenAddr;

    constructor(address _asyncSwapAddr, address _timelockAddr, address _asyncTokenAddr) {
        asyncSwapAddr = _asyncSwapAddr;
        timelockAddr = _timelockAddr;
        asyncTokenAddr = _asyncTokenAddr;
    }

    function _readDeployedContractAddress(string memory scriptName, uint256 txIndex)
        internal
        view
        override
        returns (address)
    {
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

contract SetAsyncTokenMinterHarness is SetAsyncTokenMinterScript {
    address internal asyncSwapAddr;
    address internal timelockAddr;
    address internal asyncTokenAddr;

    constructor(address _asyncSwapAddr, address _timelockAddr, address _asyncTokenAddr) {
        asyncSwapAddr = _asyncSwapAddr;
        timelockAddr = _timelockAddr;
        asyncTokenAddr = _asyncTokenAddr;
    }

    function _readDeployedContractAddress(string memory scriptName, uint256 txIndex)
        internal
        view
        override
        returns (address)
    {
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

contract ScheduleOwnershipHarness is ScheduleAsyncSwapOwnershipAcceptanceScript {
    address internal asyncSwapAddr;
    address internal timelockAddr;

    constructor(address _asyncSwapAddr, address _timelockAddr) {
        asyncSwapAddr = _asyncSwapAddr;
        timelockAddr = _timelockAddr;
    }

    function _deployedAsyncSwap() internal view override returns (address) {
        return asyncSwapAddr;
    }

    function _deployedTimelock() internal view override returns (address) {
        return timelockAddr;
    }
}

contract ExecuteOwnershipHarness is ExecuteAsyncSwapOwnershipAcceptanceScript {
    address internal asyncSwapAddr;
    address internal timelockAddr;

    constructor(address _asyncSwapAddr, address _timelockAddr) {
        asyncSwapAddr = _asyncSwapAddr;
        timelockAddr = _timelockAddr;
    }

    function _deployedAsyncSwap() internal view override returns (address) {
        return asyncSwapAddr;
    }

    function _deployedTimelock() internal view override returns (address) {
        return timelockAddr;
    }
}

contract RevokeBootstrapHarness is RevokeBootstrapTimelockRolesScript {
    address internal timelockAddr;
    address internal governorAddr;

    constructor(address _timelockAddr, address _governorAddr) {
        timelockAddr = _timelockAddr;
        governorAddr = _governorAddr;
    }

    function _deployedTimelock() internal view override returns (address) {
        return timelockAddr;
    }

    function _deployedGovernor() internal view override returns (address) {
        return governorAddr;
    }
}

contract MockIntentOwned {
    address public pendingOwner;
    address public protocolOwner;

    constructor() {
        protocolOwner = msg.sender;
    }

    function transferOwnership(address newOwner) external {
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NOT_PENDING_OWNER");
        protocolOwner = msg.sender;
        pendingOwner = address(0);
    }
}

contract MockMintAdmin {
    address public minter;

    function setMinter(address newMinter) external {
        minter = newMinter;
    }
}
