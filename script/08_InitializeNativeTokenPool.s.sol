// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {ScriptHelper} from "./ScriptHelper.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract InitializeNativeTokenPoolScript is ScriptHelper {
    function run() public {
        address asyncSwap = _deployedAsyncSwap();
        address token = vm.envOr("TOKEN1_ADDRESS", _deployedDemoToken1());
        uint160 sqrtPriceX96 = uint160(vm.envOr("SQRT_PRICE_X96", uint256(79228162514264337593543950336)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(240))));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(asyncSwap)
        });

        vm.startBroadcast();
        IPoolManager(_poolManagerAddress()).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();
    }
}
