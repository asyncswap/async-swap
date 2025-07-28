// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { FFIHelper } from "./FFIHelper.sol";
import { AsyncSwap } from "@async-swap/AsyncSwap.sol";
import { console } from "forge-std/Test.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @notice Scripts to intialize pool

contract IntializePool is FFIHelper {

  IPoolManager manager;
  AsyncSwap hook;
  Currency currency0;
  Currency currency1;
  PoolKey key;
  uint24 FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
  int24 TICK_SPACING = 60;

  function setUp() public {
    manager = IPoolManager(_getDeployedPoolManager());
    (address _hook,) = _getDeployedHook();
    hook = AsyncSwap(_hook);
  }

  function run() public {
    vm.startBroadcast();

    intilizePool();

    vm.stopBroadcast();
  }

  function intilizePool() public {
    /// @dev deploy tokens
    MockERC20 rUSD = new MockERC20("Async USDC", "aUSDC", 18);
    MockERC20 usdc = new MockERC20("Test USDC", "tUSDC", 6);
    rUSD.mint(OWNER, 1000e18);
    usdc.mint(OWNER, 1000e18);

    /// @dev set currency0 and currency1 order
    if (rUSD < usdc) {
      currency0 = Currency.wrap(address(rUSD));
      currency1 = Currency.wrap(address(usdc));
    } else {
      currency0 = Currency.wrap(address(usdc));
      currency1 = Currency.wrap(address(rUSD));
    }

    /// @dev set poolkey
    key = PoolKey(currency0, currency1, FEE, TICK_SPACING, hook);

    /// @dev initialize pool
    uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1_1 (2 ** 96)
    manager.initialize(key, sqrtPriceX96);
  }

}
