// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployAsyncSwapScript} from "../script/00_DeployAsyncSwap.s.sol";
import {HookMiner} from "../script/utils/HookMiner.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract DeployScriptTest is Test {
    address internal constant LOCAL_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint24 constant HOOK_FEE = 1_2000;

    function _flags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function test_hookMiner_find_returnsFlaggedEmptyAddress() public view {
        bytes memory constructorArgs = abi.encode(address(0xBEEF), address(0xCAFE), HOOK_FEE);
        (address mined, bytes32 salt) =
            HookMiner.find(LOCAL_CREATE2_FACTORY, _flags(), type(AsyncSwap).creationCode, constructorArgs);

        bytes memory creationCodeWithArgs = abi.encodePacked(type(AsyncSwap).creationCode, constructorArgs);
        address recomputed = HookMiner.computeAddress(LOCAL_CREATE2_FACTORY, uint256(salt), creationCodeWithArgs);

        assertEq(mined, recomputed, "mined address mismatch");
        assertEq(uint160(mined) & Hooks.ALL_HOOK_MASK, _flags(), "hook flags mismatch");
        assertEq(mined.code.length, 0, "mined address should be empty");
    }

    function test_deployScript_run_deploysMinedHook() public {
        address deployer = makeAddr("deployer");
        vm.deal(deployer, 100 ether);
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));

        DeployAsyncSwapScript script = new DeployAsyncSwapScript();
        script.run();

        address managerAddr = address(script.manager());
        address hookAddr = address(script.hook());

        assertTrue(managerAddr != address(0), "manager not deployed");
        assertTrue(hookAddr != address(0), "hook not deployed");
        assertEq(uint160(hookAddr) & Hooks.ALL_HOOK_MASK, _flags(), "deployed hook flags mismatch");
        assertEq(address(AsyncSwap(hookAddr).POOL_MANAGER()), managerAddr, "hook manager mismatch");
        // Owner is set via constructor arg, not msg.sender, so it matches DEPLOYER_ADDRESS
        assertEq(AsyncSwap(hookAddr).protocolOwner(), deployer, "hook owner mismatch");
    }
}
