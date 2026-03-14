// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {ScriptHelper} from "./ScriptHelper.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract CreateDemoOrderScript is ScriptHelper {
    function run() public {
        address asyncSwap = _deployedAsyncSwap();
        address user = vm.envAddress("USER_ADDRESS");
        address tokenA = _deployedDemoToken0();
        address tokenB = _deployedDemoToken1();
        uint256 amountIn = vm.envOr("ORDER_AMOUNT_IN", uint256(1e18));
        int24 tick = int24(vm.envInt("ORDER_TICK"));
        uint256 minAmountOut = vm.envOr("MIN_AMOUNT_OUT", uint256(0));
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(240))));

        Currency currencyA = Currency.wrap(tokenA);
        Currency currencyB = Currency.wrap(tokenB);
        (Currency currency0, Currency currency1) = tokenA < tokenB ? (currencyA, currencyB) : (currencyB, currencyA);

        address router = address(AsyncSwap(asyncSwap).router());

        vm.startBroadcast(user);
        MockERC20(tokenA).approve(router, type(uint256).max);
        MockERC20(tokenB).approve(router, type(uint256).max);

        AsyncSwap(asyncSwap).swap(
            PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: tickSpacing,
                hooks: IHooks(asyncSwap)
            }),
            zeroForOne,
            amountIn,
            tick,
            minAmountOut
        );
        vm.stopBroadcast();
    }
}
