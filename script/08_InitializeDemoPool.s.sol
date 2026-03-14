// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ScriptHelper} from "./ScriptHelper.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract InitializeDemoPoolScript is ScriptHelper {
    function run() public {
        address asyncSwap = _deployedAsyncSwap();
        address tokenA = _deployedDemoToken0();
        address tokenB = _deployedDemoToken1();
        uint160 sqrtPriceX96 = uint160(vm.envOr("SQRT_PRICE_X96", uint256(79228162514264337593543950336)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(240))));

        Currency currencyA = Currency.wrap(tokenA);
        Currency currencyB = Currency.wrap(tokenB);
        (Currency currency0, Currency currency1) = tokenA < tokenB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(asyncSwap)
        });

        vm.startBroadcast();
        IPoolManager(_poolManagerAddress()).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();
    }
}
