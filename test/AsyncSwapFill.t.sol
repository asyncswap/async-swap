// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {AsyncRouter} from "../src/AsyncRouter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

contract AsyncSwapFillTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AsyncSwap hook;
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
        AsyncSwap impl = new AsyncSwap(manager);
        vm.etch(hookAddr, address(impl).code);
        hook = AsyncSwap(hookAddr);

        bytes32 slot1000 = bytes32(uint256(uint160(address(this)))) << 24 | bytes32(uint256(HOOK_FEE));
        vm.store(hookAddr, bytes32(uint256(1000)), slot1000);

        // Deploy router and set it as the trusted router on the hook
        AsyncRouter asyncRouter = new AsyncRouter(manager, hookAddr);
        hook.setRouter(address(asyncRouter));

        // Approve router for settle (CurrencySettler.transferFrom is called by router as msg.sender)
        MockERC20(Currency.unwrap(currency0)).approve(address(asyncRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(asyncRouter), type(uint256).max);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: HOOK_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    // ========================================
    // Helpers
    // ========================================

    function _makeOrder(address swapper, int24 tick) internal view returns (AsyncSwap.Order memory) {
        return AsyncSwap.Order({poolId: poolId, swapper: swapper, tick: tick});
    }

    function _swap(bool zeroForOne, uint256 amountIn, int24 tick, uint256 minAmountOut) internal {
        hook.swap(poolKey, zeroForOne, amountIn, tick, minAmountOut);
    }

    function _createSwapOrder(uint256 swapAmount, int24 tick, bool zeroForOne)
        internal
        returns (AsyncSwap.Order memory order, uint256 expectedOut)
    {
        order = _makeOrder(address(this), tick);
        _swap(zeroForOne, swapAmount, tick, 0);
        expectedOut = hook.getBalanceOut(order, zeroForOne);
    }

    function _setupFiller(address filler, Currency outputCurrency, uint256 amount) internal {
        MockERC20(Currency.unwrap(outputCurrency)).mint(filler, amount);
        vm.prank(filler);
        MockERC20(Currency.unwrap(outputCurrency)).approve(address(hook), type(uint256).max);
    }

    // ========================================
    // Full fill
    // ========================================

    function test_fill_fullFill_zeroForOne() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, expectedOut);

        uint256 swapperOutBefore = currency1.balanceOf(address(this));
        uint256 fillerClaimsBefore = manager.balanceOf(filler, currency0.toId());

        vm.prank(filler);
        hook.fill(order, true, expectedOut);

        assertEq(currency1.balanceOf(address(this)) - swapperOutBefore, expectedOut, "swapper did not receive output");

        uint256 fillerClaimsAfter = manager.balanceOf(filler, currency0.toId());
        assertEq(fillerClaimsAfter - fillerClaimsBefore, swapAmount, "filler did not receive input claims");

        assertEq(hook.getBalanceOut(order, true), 0, "balanceOut not zero after full fill");
        assertEq(hook.getBalanceIn(order, true), 0, "balanceIn not zero after full fill");
    }

    function test_fill_fullFill_oneForZero() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, false);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency0, expectedOut);

        uint256 swapperOutBefore = currency0.balanceOf(address(this));

        vm.prank(filler);
        hook.fill(order, false, expectedOut);

        assertEq(currency0.balanceOf(address(this)) - swapperOutBefore, expectedOut, "swapper did not receive output");
        assertEq(hook.getBalanceOut(order, false), 0, "balanceOut not zero");
        assertEq(hook.getBalanceIn(order, false), 0, "balanceIn not zero");
    }

    // ========================================
    // Partial fills — two fills to complete
    // ========================================

    function test_fill_twoPartialFills() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler1 = makeAddr("filler1");
        address filler2 = makeAddr("filler2");
        _setupFiller(filler1, currency1, expectedOut);
        _setupFiller(filler2, currency1, expectedOut);

        // First fill: exactly 50% (minimum allowed)
        uint256 fill1Amount = (expectedOut + 1) / 2;
        vm.prank(filler1);
        hook.fill(order, true, fill1Amount);

        uint256 remainingOut = hook.getBalanceOut(order, true);
        assertEq(remainingOut, expectedOut - fill1Amount, "remaining out after first fill");

        // Second fill: the rest
        vm.prank(filler2);
        hook.fill(order, true, remainingOut);

        assertEq(hook.getBalanceOut(order, true), 0, "order not fully filled");
        assertEq(hook.getBalanceIn(order, true), 0, "input not fully distributed");
    }

    // ========================================
    // Minimum fill enforcement
    // ========================================

    function test_fill_belowMinimum_reverts() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, expectedOut);

        uint256 tooSmall = expectedOut / 2 - 1;
        vm.prank(filler);
        vm.expectRevert(AsyncSwap.FILL_AMOUNT_TOO_SMALL.selector);
        hook.fill(order, true, tooSmall);
    }

    // ========================================
    // Already filled
    // ========================================

    function test_fill_alreadyFilled_reverts() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, expectedOut);

        vm.prank(filler);
        hook.fill(order, true, expectedOut);

        vm.prank(filler);
        vm.expectRevert(AsyncSwap.ORDER_ALREADY_FILLED.selector);
        hook.fill(order, true, 1);
    }

    // ========================================
    // Exceeds remaining
    // ========================================

    function test_fill_exceedsRemaining_reverts() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, expectedOut + 1);

        vm.prank(filler);
        vm.expectRevert(AsyncSwap.FILL_EXCEEDS_REMAINING.selector);
        hook.fill(order, true, expectedOut + 1);
    }

    // ========================================
    // Fill emits event
    // ========================================

    function test_fill_emitsEvent() public {
        uint256 swapAmount = 5e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, expectedOut);

        bytes32 expectedOrderId = keccak256(abi.encode(order));

        vm.expectEmit(true, false, false, true, address(hook));
        emit AsyncSwap.Fill(expectedOrderId, filler, expectedOut, swapAmount);

        vm.prank(filler);
        hook.fill(order, true, expectedOut);
    }

    // ========================================
    // Proportional input share
    // ========================================

    function test_fill_proportionalInputShare() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, expectedOut);

        // Fill 60% of output
        uint256 fillAmount = expectedOut * 60 / 100;
        require(fillAmount >= (expectedOut + 1) / 2, "test setup: fill too small");

        uint256 expectedInputShare = FullMath.mulDiv(fillAmount, swapAmount, expectedOut);

        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        uint256 fillerClaims = manager.balanceOf(filler, currency0.toId());
        assertEq(fillerClaims, expectedInputShare, "input share mismatch");

        assertEq(hook.getBalanceOut(order, true), expectedOut - fillAmount, "remaining out");
        assertEq(hook.getBalanceIn(order, true), swapAmount - expectedInputShare, "remaining in");
    }

    // ========================================
    // Log n convergence
    // ========================================

    function test_fill_logN_convergence() public {
        uint256 swapAmount = 100e18;
        (AsyncSwap.Order memory order,) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        // ceil(log2(100e18)) = 67 iterations worst case with 50% fills
        for (uint256 i = 0; i < 70; i++) {
            uint256 remaining = hook.getBalanceOut(order, true);
            if (remaining == 0) break;

            address filler = makeAddr(string(abi.encodePacked("filler", i)));
            _setupFiller(filler, currency1, remaining);

            uint256 fillAmt = (remaining + 1) / 2;
            vm.prank(filler);
            hook.fill(order, true, fillAmt);
        }

        assertEq(hook.getBalanceOut(order, true), 0, "order not fully filled after log-n fills");
        assertEq(hook.getBalanceIn(order, true), 0, "input not fully distributed");
    }

    // ========================================
    // Permissionless
    // ========================================

    function test_fill_permissionless() public {
        uint256 swapAmount = 5e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address rando = makeAddr("rando");
        _setupFiller(rando, currency1, expectedOut);

        vm.prank(rando);
        hook.fill(order, true, expectedOut);

        assertEq(hook.getBalanceOut(order, true), 0, "fill should succeed from any address");
    }

    // ========================================
    // Fuzz: fill invariants
    // ========================================

    function testFuzz_fill_invariants(uint256 swapAmount, uint256 fillPct) public {
        swapAmount = bound(swapAmount, 1e15, 1e24);
        fillPct = bound(fillPct, 50, 100);

        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        _swap(true, swapAmount, ORDER_TICK, 0);

        uint256 totalOut = hook.getBalanceOut(order, true);
        uint256 totalIn = hook.getBalanceIn(order, true);
        if (totalOut == 0) return;

        uint256 fillAmount = totalOut * fillPct / 100;
        uint256 minFill = (totalOut + 1) / 2;
        if (fillAmount < minFill) fillAmount = minFill;
        if (fillAmount > totalOut) fillAmount = totalOut;

        uint256 expectedInputShare = FullMath.mulDiv(fillAmount, totalIn, totalOut);

        address filler = makeAddr("fuzzFiller");
        _setupFiller(filler, currency1, fillAmount);

        uint256 swapperBefore = currency1.balanceOf(address(this));

        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        // Invariant 1: swapper received exact fillAmount
        assertEq(currency1.balanceOf(address(this)) - swapperBefore, fillAmount, "fuzz: swapper output mismatch");

        // Invariant 2: filler received proportional input claims
        assertEq(manager.balanceOf(filler, currency0.toId()), expectedInputShare, "fuzz: filler claims mismatch");

        // Invariant 3: remaining balances correct
        assertEq(hook.getBalanceOut(order, true), totalOut - fillAmount, "fuzz: remaining out");
        assertEq(hook.getBalanceIn(order, true), totalIn - expectedInputShare, "fuzz: remaining in");

        // Invariant 4: input share never exceeds total
        assertLe(expectedInputShare, totalIn, "fuzz: input share exceeds total");
    }

    function testFuzz_fill_multipleFillers(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1e15, 1e24);

        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        _swap(true, swapAmount, ORDER_TICK, 0);

        uint256 totalOut = hook.getBalanceOut(order, true);
        uint256 totalIn = hook.getBalanceIn(order, true);
        if (totalOut == 0) return;

        uint256 totalClaimsDistributed;

        // Fill with 50% each time until done — ceil(log2(totalOut)) iterations worst case
        for (uint256 i = 0; i < 80; i++) {
            uint256 remaining = hook.getBalanceOut(order, true);
            if (remaining == 0) break;

            address filler = makeAddr(string(abi.encodePacked("f", i)));
            _setupFiller(filler, currency1, remaining);

            uint256 fillAmt = (remaining + 1) / 2;
            vm.prank(filler);
            hook.fill(order, true, fillAmt);

            totalClaimsDistributed += manager.balanceOf(filler, currency0.toId());
        }

        // All output distributed, all input claims distributed
        assertEq(hook.getBalanceOut(order, true), 0, "fuzz: order not fully filled");
        assertEq(hook.getBalanceIn(order, true), 0, "fuzz: input not fully distributed");
        assertEq(totalClaimsDistributed, totalIn, "fuzz: total claims mismatch");
    }

    // ================================================================
    //                        CANCEL TESTS
    // ================================================================

    // ========================================
    // Full cancel — swapper reclaims all input
    // ========================================

    function test_cancel_zeroForOne() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order,) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        uint256 swapperBalBefore = currency0.balanceOf(address(this));

        hook.cancelOrder(order, true);

        assertEq(currency0.balanceOf(address(this)) - swapperBalBefore, swapAmount, "swapper did not receive input back");
        assertEq(hook.getBalanceIn(order, true), 0, "balanceIn not zero");
        assertEq(hook.getBalanceOut(order, true), 0, "balanceOut not zero");
    }

    function test_cancel_oneForZero() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order,) = _createSwapOrder(swapAmount, ORDER_TICK, false);

        uint256 swapperBalBefore = currency1.balanceOf(address(this));

        hook.cancelOrder(order, false);

        assertEq(currency1.balanceOf(address(this)) - swapperBalBefore, swapAmount, "swapper did not receive input back");
        assertEq(hook.getBalanceIn(order, false), 0, "balanceIn not zero");
        assertEq(hook.getBalanceOut(order, false), 0, "balanceOut not zero");
    }

    // ========================================
    // Cancel after partial fill — reclaims remaining
    // ========================================

    function test_cancel_afterPartialFill() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        // Filler fills 50%
        address filler = makeAddr("filler");
        uint256 fillAmount = (expectedOut + 1) / 2;
        _setupFiller(filler, currency1, fillAmount);

        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        uint256 remainingIn = hook.getBalanceIn(order, true);
        uint256 swapperBalBefore = currency0.balanceOf(address(this));

        hook.cancelOrder(order, true);

        assertEq(currency0.balanceOf(address(this)) - swapperBalBefore, remainingIn, "cancel after fill: wrong refund");
        assertEq(hook.getBalanceIn(order, true), 0, "balanceIn not zero");
        assertEq(hook.getBalanceOut(order, true), 0, "balanceOut not zero");
    }

    // ========================================
    // Cancel by non-owner reverts
    // ========================================

    function test_cancel_nonOwner_reverts() public {
        uint256 swapAmount = 5e18;
        (AsyncSwap.Order memory order,) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(AsyncSwap.NOT_ORDER_OWNER.selector);
        hook.cancelOrder(order, true);
    }

    // ========================================
    // Cancel with nothing remaining reverts
    // ========================================

    function test_cancel_nothingRemaining_reverts() public {
        uint256 swapAmount = 5e18;
        (AsyncSwap.Order memory order,) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        // Cancel once
        hook.cancelOrder(order, true);

        // Cancel again — nothing left
        vm.expectRevert(AsyncSwap.NOTHING_TO_CANCEL.selector);
        hook.cancelOrder(order, true);
    }

    // ========================================
    // Cancel emits event
    // ========================================

    function test_cancel_emitsEvent() public {
        uint256 swapAmount = 5e18;
        (AsyncSwap.Order memory order,) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        bytes32 expectedOrderId = keccak256(abi.encode(order));

        vm.expectEmit(true, false, false, true, address(hook));
        emit AsyncSwap.Cancel(expectedOrderId, address(this), swapAmount);

        hook.cancelOrder(order, true);
    }

    // ========================================
    // Cancel fully filled order reverts
    // ========================================

    function test_cancel_alreadyFilled_reverts() public {
        uint256 swapAmount = 5e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, expectedOut);
        vm.prank(filler);
        hook.fill(order, true, expectedOut);

        vm.expectRevert(AsyncSwap.NOTHING_TO_CANCEL.selector);
        hook.cancelOrder(order, true);
    }

    // ========================================
    // Fuzz: cancel returns all remaining input
    // ========================================

    function testFuzz_cancel_returnsAllInput(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1e15, 1e24);

        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        _swap(true, swapAmount, ORDER_TICK, 0);

        uint256 totalIn = hook.getBalanceIn(order, true);
        if (totalIn == 0) return;

        uint256 swapperBefore = currency0.balanceOf(address(this));

        hook.cancelOrder(order, true);

        // Swapper received all remaining input
        assertEq(currency0.balanceOf(address(this)) - swapperBefore, totalIn, "fuzz: cancel refund wrong");

        // Storage cleared
        assertEq(hook.getBalanceIn(order, true), 0, "fuzz: balanceIn not zero");
        assertEq(hook.getBalanceOut(order, true), 0, "fuzz: balanceOut not zero");
    }

    function testFuzz_fillThenCancel(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1e15, 1e24);

        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        _swap(true, swapAmount, ORDER_TICK, 0);

        uint256 totalOut = hook.getBalanceOut(order, true);
        if (totalOut == 0) return;

        // Fill 50%
        uint256 fillAmount = (totalOut + 1) / 2;
        address filler = makeAddr("fuzzFiller");
        _setupFiller(filler, currency1, fillAmount);

        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        // Cancel the rest
        uint256 remainingIn = hook.getBalanceIn(order, true);
        uint256 swapperBefore = currency0.balanceOf(address(this));

        hook.cancelOrder(order, true);

        assertEq(currency0.balanceOf(address(this)) - swapperBefore, remainingIn, "fuzz: cancel after fill wrong");
        assertEq(hook.getBalanceIn(order, true), 0, "fuzz: in not zero");
        assertEq(hook.getBalanceOut(order, true), 0, "fuzz: out not zero");
    }
}
