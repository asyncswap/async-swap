// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { FFIHelper } from "./FFIHelper.sol";
import { Router } from "@async-swap/router.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { IERC20Minimal } from "v4-core/interfaces/external/IERC20Minimal.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

contract SwapScript is FFIHelper {

  PoolId poolId;
  Currency currency0;
  Currency currency1;
  PoolKey key;
  Router router;
  AsyncOrder order;

  function setUp() public {
    (, address _router) = _getDeployedHook();
    router = Router(_router);
    key = _getPoolKey();
  }

  function swap() public { }

  function run() public {
    vm.startBroadcast(OWNER);

    uint256 amount = 100;
    bool zeroForOne = true;
    order = AsyncOrder(key, OWNER, zeroForOne, amount, 2 ** 96);

    if (zeroForOne) {
      IERC20Minimal(Currency.unwrap(order.key.currency0)).approve(address(router), uint256(amount));
    } else {
      IERC20Minimal(Currency.unwrap(order.key.currency1)).approve(address(router), uint256(amount));
    }

    bytes memory routerData = abi.encode(OWNER, router);
    router.swap(order, routerData);

    vm.stopBroadcast();
  }

}
