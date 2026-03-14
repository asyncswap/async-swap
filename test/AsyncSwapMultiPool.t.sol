// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

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

contract AsyncSwapMultiPoolTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AsyncSwap hook;
    AsyncRouter asyncRouter;

    // Pool 1 — default currencies from Deployers
    PoolKey poolKey1;
    PoolId poolId1;

    // Pool 2 — separate token pair
    MockERC20 tokenA;
    MockERC20 tokenB;
    Currency currencyA;
    Currency currencyB;
    PoolKey poolKey2;
    PoolId poolId2;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint24 constant HOOK_FEE = 1_2000;
    int24 constant TICK_SPACING = 240;
    int24 constant ORDER_TICK = 0;

    function _netInput(uint256 amount) internal pure returns (uint256) {
        uint256 fee = FullMath.mulDivRoundingUp(amount, HOOK_FEE, 1_000_000);
        return amount - fee;
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy hook
        address hookAddr = address(HOOK_FLAGS);
        deployCodeTo("AsyncSwap.sol:AsyncSwap", abi.encode(address(manager), address(this)), hookAddr);
        hook = AsyncSwap(hookAddr);
        asyncRouter = hook.router();

        // Approve router for pool 1 tokens
        MockERC20(Currency.unwrap(currency0)).approve(address(asyncRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(asyncRouter), type(uint256).max);

        // Initialize pool 1
        poolKey1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        poolId1 = poolKey1.toId();
        manager.initialize(poolKey1, SQRT_PRICE_1_1);

        // Deploy pool 2 tokens
        tokenA = new MockERC20("TokenA", "A", 18);
        tokenB = new MockERC20("TokenB", "B", 18);
        (currencyA, currencyB) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        // Mint and approve pool 2 tokens
        MockERC20(Currency.unwrap(currencyA)).mint(address(this), 1000e18);
        MockERC20(Currency.unwrap(currencyB)).mint(address(this), 1000e18);
        MockERC20(Currency.unwrap(currencyA)).approve(address(asyncRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(address(asyncRouter), type(uint256).max);

        // Initialize pool 2
        poolKey2 = PoolKey({
            currency0: currencyA,
            currency1: currencyB,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        poolId2 = poolKey2.toId();
        manager.initialize(poolKey2, SQRT_PRICE_1_1);
    }

    // ========================================
    // Orders on different pools are independent
    // ========================================

    function test_ordersOnDifferentPoolsAreIndependent() public {
        uint256 swapAmount1 = 5e18;
        uint256 swapAmount2 = 3e18;

        hook.swap(poolKey1, true, swapAmount1, ORDER_TICK, 0, 0);
        hook.swap(poolKey2, true, swapAmount2, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order1 = AsyncSwap.Order({poolId: poolId1, swapper: address(this), tick: ORDER_TICK});
        AsyncSwap.Order memory order2 = AsyncSwap.Order({poolId: poolId2, swapper: address(this), tick: ORDER_TICK});

        assertEq(hook.getBalanceIn(order1, true), _netInput(swapAmount1), "pool1 balanceIn");
        assertEq(hook.getBalanceIn(order2, true), _netInput(swapAmount2), "pool2 balanceIn");
    }

    // ========================================
    // Cancel on one pool doesn't affect another
    // ========================================

    function test_cancelOnOnePoolDoesNotAffectAnother() public {
        uint256 swapAmount1 = 5e18;
        uint256 swapAmount2 = 3e18;

        hook.swap(poolKey1, true, swapAmount1, ORDER_TICK, 0, 0);
        hook.swap(poolKey2, true, swapAmount2, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order1 = AsyncSwap.Order({poolId: poolId1, swapper: address(this), tick: ORDER_TICK});
        AsyncSwap.Order memory order2 = AsyncSwap.Order({poolId: poolId2, swapper: address(this), tick: ORDER_TICK});

        // Cancel pool 1
        hook.cancelOrder(order1, true);

        assertEq(hook.getBalanceIn(order1, true), 0, "pool1 should be cancelled");
        assertEq(hook.getBalanceIn(order2, true), _netInput(swapAmount2), "pool2 should be unaffected");
    }

    // ========================================
    // Fill on one pool doesn't affect another
    // ========================================

    function test_fillOnOnePoolDoesNotAffectAnother() public {
        uint256 swapAmount1 = 5e18;
        uint256 swapAmount2 = 3e18;

        hook.swap(poolKey1, true, swapAmount1, ORDER_TICK, 0, 0);
        hook.swap(poolKey2, true, swapAmount2, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order1 = AsyncSwap.Order({poolId: poolId1, swapper: address(this), tick: ORDER_TICK});
        AsyncSwap.Order memory order2 = AsyncSwap.Order({poolId: poolId2, swapper: address(this), tick: ORDER_TICK});

        uint256 out1 = hook.getBalanceOut(order1, true);

        // Fill pool 1 — filler provides currency1 (output for zeroForOne on pool1)
        address filler = makeAddr("filler");
        MockERC20(Currency.unwrap(currency1)).mint(filler, out1);
        vm.prank(filler);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.prank(filler);
        hook.fill(order1, true, out1);

        // Pool 1 fully filled
        assertEq(hook.getBalanceIn(order1, true), 0, "pool1 should be fully filled");
        assertEq(hook.getBalanceOut(order1, true), 0, "pool1 out should be zero");

        // Pool 2 unaffected
        assertEq(hook.getBalanceIn(order2, true), _netInput(swapAmount2), "pool2 balanceIn should be unaffected");
        assertGt(hook.getBalanceOut(order2, true), 0, "pool2 balanceOut should be unaffected");
    }

    // ========================================
    // Same user, same tick, different pools — different orderIds
    // ========================================

    function test_sameUserSameTickDifferentPools_differentOrderIds() public {
        hook.swap(poolKey1, true, 5e18, ORDER_TICK, 0, 0);
        hook.swap(poolKey2, true, 5e18, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order1 = AsyncSwap.Order({poolId: poolId1, swapper: address(this), tick: ORDER_TICK});
        AsyncSwap.Order memory order2 = AsyncSwap.Order({poolId: poolId2, swapper: address(this), tick: ORDER_TICK});

        bytes32 orderId1 = keccak256(abi.encode(order1));
        bytes32 orderId2 = keccak256(abi.encode(order2));

        assertTrue(orderId1 != orderId2, "orderIds should differ for different pools");
    }

    // ========================================
    // Accumulation within same pool, independence across pools
    // ========================================

    function test_accumulationWithinPool_independenceAcross() public {
        // Two swaps on pool 1, one swap on pool 2
        hook.swap(poolKey1, true, 3e18, ORDER_TICK, 0, 0);
        hook.swap(poolKey1, true, 2e18, ORDER_TICK, 0, 0);
        hook.swap(poolKey2, true, 7e18, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order1 = AsyncSwap.Order({poolId: poolId1, swapper: address(this), tick: ORDER_TICK});
        AsyncSwap.Order memory order2 = AsyncSwap.Order({poolId: poolId2, swapper: address(this), tick: ORDER_TICK});

        // Pool 1 accumulated
        assertEq(hook.getBalanceIn(order1, true), _netInput(3e18) + _netInput(2e18), "pool1 should accumulate 3+2");

        // Pool 2 independent
        assertEq(hook.getBalanceIn(order2, true), _netInput(7e18), "pool2 should have 7");
    }
}
