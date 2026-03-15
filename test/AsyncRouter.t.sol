// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {AsyncRouter} from "../src/AsyncRouter.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

contract AsyncRouterTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AsyncSwap hook;
    AsyncRouter asyncRouter;
    PoolKey poolKey;
    PoolId poolId;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint24 constant HOOK_FEE = 1_2000;
    int24 constant TICK_SPACING = 240;
    int24 constant ORDER_TICK = 0;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(HOOK_FLAGS);
        deployCodeTo("AsyncSwap.sol:AsyncSwap", abi.encode(address(manager), address(this)), hookAddr);
        hook = AsyncSwap(hookAddr);
        asyncRouter = hook.router();

        MockERC20(Currency.unwrap(currency0)).approve(address(asyncRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(asyncRouter), type(uint256).max);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        hook.unpause();
    }

    // ========================================
    // Router deployment
    // ========================================

    function test_router_deployment() public view {
        assertEq(address(asyncRouter.POOL_MANAGER()), address(manager));
        assertEq(asyncRouter.HOOK(), address(hook));
    }

    // ========================================
    // executeSwap — only hook can call
    // ========================================

    function test_executeSwap_onlyHook_reverts() public {
        AsyncRouter.SwapData memory data = AsyncRouter.SwapData({
            user: address(this),
            key: poolKey,
            tick: ORDER_TICK,
            amountIn: 1e18,
            zeroForOne: true,
            minAmountOut: 0,
            value: 0
        });

        // Random address calling executeSwap should revert
        vm.expectRevert(AsyncRouter.ONLY_HOOK.selector);
        asyncRouter.executeSwap(data);
    }

    function testFuzz_executeSwap_nonHookReverts(address caller) public {
        vm.assume(caller != address(hook));

        AsyncRouter.SwapData memory data = AsyncRouter.SwapData({
            user: address(this),
            key: poolKey,
            tick: ORDER_TICK,
            amountIn: 1e18,
            zeroForOne: true,
            minAmountOut: 0,
            value: 0
        });

        vm.prank(caller);
        vm.expectRevert(AsyncRouter.ONLY_HOOK.selector);
        asyncRouter.executeSwap(data);
    }

    // ========================================
    // unlockCallback — only PoolManager can call
    // ========================================

    function test_unlockCallback_onlyPoolManager_reverts() public {
        vm.expectRevert(AsyncRouter.ONLY_POOL_MANAGER.selector);
        asyncRouter.unlockCallback("");
    }

    function testFuzz_unlockCallback_nonPMReverts(address caller) public {
        vm.assume(caller != address(manager));

        vm.prank(caller);
        vm.expectRevert(AsyncRouter.ONLY_POOL_MANAGER.selector);
        asyncRouter.unlockCallback("");
    }

    // ========================================
    // Router is immutable and deployed by constructor
    // ========================================

    function test_router_isImmutable() public view {
        // Router is deployed in constructor, cannot be changed
        assertEq(address(hook.router()), address(asyncRouter));
        assertEq(asyncRouter.HOOK(), address(hook));
    }

    // ========================================
    // unlockCallback on hook — only PoolManager
    // ========================================

    function test_hook_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(AsyncSwap.CALLER_NOT_POOL_MANAGER_CALLBACK.selector);
        hook.unlockCallback("");
    }

    function testFuzz_hook_unlockCallback_nonPMReverts(address caller) public {
        vm.assume(caller != address(manager));

        vm.prank(caller);
        vm.expectRevert(AsyncSwap.CALLER_NOT_POOL_MANAGER_CALLBACK.selector);
        hook.unlockCallback("");
    }

    // ========================================
    // Swap through hook.swap() works end-to-end
    // ========================================

    function _netInput(uint256 amount) internal pure returns (uint256) {
        uint256 fee = FullMath.mulDivRoundingUp(amount, HOOK_FEE, 1_000_000);
        return amount - fee;
    }

    function test_swap_endToEnd() public {
        uint256 swapAmount = 5e18;

        uint256 balBefore = currency0.balanceOf(address(this));
        hook.swap(poolKey, true, swapAmount, ORDER_TICK, 0, 0);
        uint256 balAfter = currency0.balanceOf(address(this));

        assertEq(balBefore - balAfter, swapAmount, "user did not pay input");

        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: poolId, swapper: address(this), tick: ORDER_TICK});
        assertEq(hook.getBalanceIn(order, true), _netInput(swapAmount), "balanceIn mismatch");
        assertGt(hook.getBalanceOut(order, true), 0, "balanceOut should be > 0");
    }
}
