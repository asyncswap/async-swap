// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ScriptHelper} from "./ScriptHelper.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Order, OrderLibrary} from "src/types/Order.sol";

contract FillDemoOrderScript is ScriptHelper {
    using PoolIdLibrary for PoolKey;
    using OrderLibrary for Order;

    function run() public {
        address asyncSwap = _deployedAsyncSwap();
        address user = vm.envAddress("USER_ADDRESS");
        address filler = vm.envAddress("FILLER_ADDRESS");
        address tokenA = _deployedDemoToken0();
        address tokenB = _deployedDemoToken1();
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);
        int24 tick = int24(vm.envInt("ORDER_TICK"));
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

        Order memory order = Order({poolId: key.toId(), swapper: user, tick: tick});
        uint256 fillAmount = vm.envOr("FILL_AMOUNT", AsyncSwap(asyncSwap).getBalanceOut(order.toId(), zeroForOne));

        address outputToken = zeroForOne ? tokenB : tokenA;

        vm.startBroadcast(filler);
        MockERC20(outputToken).approve(asyncSwap, type(uint256).max);
        AsyncSwap(asyncSwap).fill(order, zeroForOne, fillAmount);
        vm.stopBroadcast();
    }
}
