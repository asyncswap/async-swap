// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { FFIHelper } from "./FFIHelper.sol";
import { Router } from "@async-swap/router.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { console } from "forge-std/Test.sol";
import { IERC20Minimal } from "v4-core/interfaces/external/IERC20Minimal.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

contract ExecuteAsyncOrderScript is FFIHelper {

  AsyncOrder order;
  Router router;

  function setUp() public {
    (, address _router) = _getDeployedHook();
    router = Router(_router);
    order = _getAsyncOrder();
    // order.sqrtPrice = 2 ** 96;
  }

  function run() public {
    vm.startBroadcast(OWNER);
    if (order.zeroForOne) {
      IERC20Minimal(Currency.unwrap(order.key.currency1)).approve(address(router), order.amountIn);
    } else {
      IERC20Minimal(Currency.unwrap(order.key.currency0)).approve(address(router), order.amountIn);
    }
    router.fillOrder(order, abi.encode(router));
    vm.stopBroadcast();
  }

}
