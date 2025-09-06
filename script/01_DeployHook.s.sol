// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { FFIHelper } from "./FFIHelper.sol";
import { AsyncSwap } from "@async-swap/AsyncSwap.sol";
import { Router } from "@async-swap/router.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { HookMiner } from "v4-periphery/src/utils/HookMiner.sol";

/// @notice Deploys Hook contract
contract DeployHookScript is FFIHelper {

  IPoolManager manager;
  AsyncSwap public hook;
  Router router;

  function setUp() public {
    manager = IPoolManager(_getDeployedPoolManager());
  }

  function run() public {
    vm.startBroadcast(OWNER);

    /// @dev get hook flags
    uint160 hookFlags = uint160(
      Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    /// @dev compute create2 salt
    (address hookAddress, bytes32 salt) =
      HookMiner.find(CREATE2_FACTORY, hookFlags, type(AsyncSwap).creationCode, abi.encode(address(manager)));

    /// @dev deploy hook
    hook = new AsyncSwap{ salt: salt }(manager);
    assert(address(hook) == hookAddress);

    router = new Router(manager, hook);

    vm.stopBroadcast();
  }

}
