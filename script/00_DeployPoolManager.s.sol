// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { FFIHelper } from "./FFIHelper.sol";
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";

contract DeployPoolManager is FFIHelper {

  IPoolManager manager;

  function run() public {
    vm.startBroadcast();

    /// @dev deploy manager
    if (chain == SelectChain.Anvil) {
      manager = new PoolManager(ANVIL_OWNER);
    } else {
      manager = new PoolManager(OWNER);
    }
  }

}
