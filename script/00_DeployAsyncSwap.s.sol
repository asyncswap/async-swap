// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {ScriptHelper} from "./ScriptHelper.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract DeployAsyncSwapScript is ScriptHelper {
    PoolManager public manager;
    AsyncSwap public hook;

    function _hookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function run() public {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        vm.startBroadcast();

        manager = new PoolManager(deployer);

        uint160 flags = _hookFlags();
        (address minedHookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(AsyncSwap).creationCode, abi.encode(address(manager)));

        hook = new AsyncSwap{salt: salt}(manager);
        require(address(hook) == minedHookAddress, "HOOK_ADDRESS_MISMATCH");

        vm.stopBroadcast();
    }
}
