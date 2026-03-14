// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {AsyncRouter} from "../src/AsyncRouter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract AsyncRouterValueValidationTest is Test {
    PoolManager manager;
    MockHookCaller mockHook;
    AsyncRouter router;
    MockERC20 token;

    function setUp() public {
        manager = new PoolManager(address(this));
        mockHook = new MockHookCaller();
        router = new AsyncRouter(manager, address(mockHook));
        mockHook.setRouter(router);
        token = new MockERC20("Token", "TKN", 18);
    }

    function test_executeSwap_nativeInput_msgValueMismatch_reverts() public {
        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 12_000,
            tickSpacing: 240,
            hooks: IHooks(address(0))
        });

        AsyncRouter.SwapData memory data = AsyncRouter.SwapData({
            user: address(this),
            key: nativeKey,
            tick: 0,
            amountIn: 1 ether,
            zeroForOne: true,
            minAmountOut: 0,
            value: 1 ether
        });

        vm.expectRevert(AsyncRouter.INVALID_NATIVE_VALUE.selector);
        mockHook.callExecuteSwap{value: 1 ether - 1}(data);
    }

    function test_executeSwap_nativeInput_dataValueMismatch_reverts() public {
        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 12_000,
            tickSpacing: 240,
            hooks: IHooks(address(0))
        });

        AsyncRouter.SwapData memory data = AsyncRouter.SwapData({
            user: address(this),
            key: nativeKey,
            tick: 0,
            amountIn: 1 ether,
            zeroForOne: true,
            minAmountOut: 0,
            value: 1 ether - 1
        });

        vm.expectRevert(AsyncRouter.INVALID_NATIVE_VALUE.selector);
        mockHook.callExecuteSwap{value: 1 ether}(data);
    }

    function test_executeSwap_erc20Input_nonzeroValue_reverts() public {
        PoolKey memory erc20Key = PoolKey({
            currency0: Currency.wrap(address(token)),
            currency1: Currency.wrap(address(0xBEEF)),
            fee: 12_000,
            tickSpacing: 240,
            hooks: IHooks(address(0))
        });

        AsyncRouter.SwapData memory data = AsyncRouter.SwapData({
            user: address(this), key: erc20Key, tick: 0, amountIn: 1e18, zeroForOne: true, minAmountOut: 0, value: 1
        });

        vm.expectRevert(AsyncRouter.INVALID_NATIVE_VALUE.selector);
        mockHook.callExecuteSwap{value: 1}(data);
    }
}

contract MockHookCaller {
    AsyncRouter internal router;

    function setRouter(AsyncRouter _router) external {
        router = _router;
    }

    function callExecuteSwap(AsyncRouter.SwapData calldata data) external payable {
        router.executeSwap{value: msg.value}(data);
    }
}
