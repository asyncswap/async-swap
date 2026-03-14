// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {IntentAuth} from "../src/IntentAuth.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

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
        deployCodeTo("AsyncSwap.sol:AsyncSwap", abi.encode(address(manager), address(this)), hookAddr);
        hook = AsyncSwap(hookAddr);

        address routerAddr = address(hook.router());
        MockERC20(Currency.unwrap(currency0)).approve(routerAddr, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(routerAddr, type(uint256).max);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
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

    function _netInput(uint256 amount) internal pure returns (uint256) {
        uint256 fee = FullMath.mulDivRoundingUp(amount, HOOK_FEE, 1_000_000);
        return amount - fee;
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

    function _initCustomPool(address inputToken, address outputToken)
        internal
        returns (PoolKey memory customKey, PoolId customPoolId, bool zeroForOne)
    {
        (Currency c0, Currency c1) = inputToken < outputToken
            ? (Currency.wrap(inputToken), Currency.wrap(outputToken))
            : (Currency.wrap(outputToken), Currency.wrap(inputToken));

        customKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        customPoolId = customKey.toId();
        zeroForOne = Currency.unwrap(c0) == inputToken;

        manager.initialize(customKey, SQRT_PRICE_1_1);
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
        assertEq(fillerClaimsAfter - fillerClaimsBefore, _netInput(swapAmount), "filler did not receive input claims");

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

    function test_feeRefundToggle_swap_tracksGrossInput_and_noImmediateFees() public {
        hook.setFeeRefundToggle(true);

        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        assertEq(hook.getBalanceIn(order, true), swapAmount, "toggle should keep gross input refundable");
        assertGt(expectedOut, 0, "quoted output should still exist");
        assertEq(hook.accruedFees(currency0), 0, "no fees should accrue at order creation");
    }

    function test_feeRefundToggle_fullFill_accruesFee_and_paysNetToFiller() public {
        hook.setFeeRefundToggle(true);

        uint256 swapAmount = 10e18;
        uint256 expectedFee = swapAmount - _netInput(swapAmount);
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, expectedOut);
        uint256 claimsBefore = manager.balanceOf(filler, currency0.toId());

        vm.prank(filler);
        hook.fill(order, true, expectedOut);

        assertEq(manager.balanceOf(filler, currency0.toId()) - claimsBefore, _netInput(swapAmount), "filler should receive net input only");
        assertEq(hook.accruedFees(currency0), expectedFee, "fee should accrue on fill");
        assertEq(hook.feeRemaining(keccak256(abi.encode(order)), true), 0, "fee remainder should clear on full fill");
    }

    function test_feeRefundToggle_cancel_returnsRemainingGrossInput() public {
        hook.setFeeRefundToggle(true);

        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, expectedOut);

        uint256 fillAmount = (expectedOut + 1) / 2;
        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        uint256 remainingGross = hook.getBalanceIn(order, true);
        bytes32 oid = keccak256(abi.encode(order));
        uint256 remainingFee = hook.feeRemaining(oid, true);
        uint256 expectedRefund = remainingGross - remainingFee;
        uint256 feeAccruedBefore = hook.accruedFees(currency0);
        uint256 balBefore = currency0.balanceOf(address(this));

        hook.cancelOrder(order, true);

        assertEq(currency0.balanceOf(address(this)) - balBefore, expectedRefund, "cancel should return remaining input minus deferred fee");
        assertEq(hook.accruedFees(currency0), feeAccruedBefore + remainingFee, "cancel should accrue remaining deferred fee");
        assertEq(hook.feeRemaining(oid, true), 0, "fee remainder should clear on cancel");
    }

    function test_upfrontFee_accountingInvariant_halfFill() public {
        uint256 swapAmount = 1e18;
        uint256 upfrontFee = swapAmount - _netInput(swapAmount);
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        uint256 fillAmount = expectedOut / 2;
        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, fillAmount);

        uint256 fillerClaimsBefore = manager.balanceOf(filler, currency0.toId());
        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        uint256 fillerPayout = manager.balanceOf(filler, currency0.toId()) - fillerClaimsBefore;
        uint256 refundableRemainder = hook.getBalanceIn(order, true);

        // Upfront mode invariant:
        // gross input = upfront fee + filler payout + refundable remainder
        // 1.0 = 0.012 + 0.494 + 0.494
        assertEq(hook.accruedFees(currency0), upfrontFee, "protocol should hold full upfront fee");
        assertEq(fillerPayout, 494_000_000_000_000_000, "filler payout mismatch");
        assertEq(refundableRemainder, 494_000_000_000_000_000, "refundable remainder mismatch");
        assertEq(upfrontFee + fillerPayout + refundableRemainder, swapAmount, "gross input invariant broken");
    }

    function test_feeRefundToggle_accountingInvariant_halfFill() public {
        hook.setFeeRefundToggle(true);

        uint256 swapAmount = 1e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        uint256 fillAmount = expectedOut / 2;
        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, fillAmount);

        uint256 fillerClaimsBefore = manager.balanceOf(filler, currency0.toId());
        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        uint256 feeOnFilledShare = hook.accruedFees(currency0);
        uint256 fillerPayout = manager.balanceOf(filler, currency0.toId()) - fillerClaimsBefore;
        uint256 refundableRemainder = hook.getBalanceIn(order, true);

        // Fee-refund-toggle invariant:
        // gross input = accrued fee on filled volume + filler payout + refundable remainder
        // 1.0 = 0.006 + 0.494 + 0.5
        assertEq(feeOnFilledShare, 6_000_000_000_000_000, "protocol should only earn fee on filled slice");
        assertEq(fillerPayout, 494_000_000_000_000_000, "filler payout mismatch");
        assertEq(refundableRemainder, 500_000_000_000_000_000, "refundable remainder mismatch");
        assertEq(feeOnFilledShare + fillerPayout + refundableRemainder, swapAmount, "gross input invariant broken");
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
        emit AsyncSwap.Fill(expectedOrderId, filler, expectedOut, _netInput(swapAmount));

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

        uint256 netIn = _netInput(swapAmount);
        uint256 expectedInputShare = FullMath.mulDiv(fillAmount, netIn, expectedOut);

        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        uint256 fillerClaims = manager.balanceOf(filler, currency0.toId());
        assertEq(fillerClaims, expectedInputShare, "input share mismatch");

        assertEq(hook.getBalanceOut(order, true), expectedOut - fillAmount, "remaining out");
        assertEq(hook.getBalanceIn(order, true), netIn - expectedInputShare, "remaining in");
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

        assertEq(
            currency0.balanceOf(address(this)) - swapperBalBefore,
            _netInput(swapAmount),
            "swapper did not receive input back"
        );
        assertEq(hook.getBalanceIn(order, true), 0, "balanceIn not zero");
        assertEq(hook.getBalanceOut(order, true), 0, "balanceOut not zero");
    }

    function test_cancel_oneForZero() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order,) = _createSwapOrder(swapAmount, ORDER_TICK, false);

        uint256 swapperBalBefore = currency1.balanceOf(address(this));

        hook.cancelOrder(order, false);

        assertEq(
            currency1.balanceOf(address(this)) - swapperBalBefore,
            _netInput(swapAmount),
            "swapper did not receive input back"
        );
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
        emit AsyncSwap.Cancel(expectedOrderId, address(this), _netInput(swapAmount));

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

    // ================================================================
    //                        EDGE CASE TESTS
    // ================================================================

    // ========================================
    // Fill on non-existent order (bogus orderId)
    // ========================================

    function test_fill_nonExistentOrder_reverts() public {
        // Order that was never created
        AsyncSwap.Order memory bogusOrder = _makeOrder(makeAddr("nobody"), 12345);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, 1e18);

        vm.prank(filler);
        vm.expectRevert(AsyncSwap.ORDER_ALREADY_FILLED.selector);
        hook.fill(bogusOrder, true, 1e18);
    }

    function test_fill_unknownPool_reverts() public {
        AsyncSwap.Order memory bogusOrder =
            AsyncSwap.Order({poolId: PoolId.wrap(bytes32(uint256(999))), swapper: address(this), tick: ORDER_TICK});

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, 1e18);

        vm.prank(filler);
        vm.expectRevert(AsyncSwap.UNKNOWN_POOL.selector);
        hook.fill(bogusOrder, true, 1e18);
    }

    function test_fill_lyingOutputToken_reverts() public {
        MockERC20 inputToken = new MockERC20("Input", "IN", 18);
        LyingTransferFromToken outputToken = new LyingTransferFromToken("Lying", "LIE", 18);

        inputToken.mint(address(this), 100e18);
        inputToken.approve(address(hook.router()), type(uint256).max);

        (PoolKey memory customKey, PoolId customPoolId, bool zeroForOne) =
            _initCustomPool(address(inputToken), address(outputToken));

        hook.swap(customKey, zeroForOne, 10e18, ORDER_TICK, 0);

        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: customPoolId, swapper: address(this), tick: ORDER_TICK});
        uint256 expectedOut = hook.getBalanceOut(order, zeroForOne);

        address filler = makeAddr("liar");
        outputToken.mint(filler, expectedOut);
        vm.prank(filler);
        outputToken.approve(address(hook), type(uint256).max);

        uint256 swapperBefore = outputToken.balanceOf(address(this));
        uint256 fillerClaimsBefore =
            manager.balanceOf(filler, (zeroForOne ? customKey.currency0 : customKey.currency1).toId());

        vm.prank(filler);
        vm.expectRevert(AsyncSwap.INSUFFICIENT_OUTPUT_RECEIVED.selector);
        hook.fill(order, zeroForOne, expectedOut);

        assertEq(outputToken.balanceOf(address(this)), swapperBefore, "swapper should receive nothing");
        assertEq(
            manager.balanceOf(filler, (zeroForOne ? customKey.currency0 : customKey.currency1).toId()),
            fillerClaimsBefore,
            "filler should not receive claims"
        );
        assertEq(hook.getBalanceOut(order, zeroForOne), expectedOut, "order output should remain unchanged");
    }

    function test_fill_feeOnTransferOutputToken_reverts() public {
        MockERC20 inputToken = new MockERC20("Input", "IN", 18);
        FeeOnTransferToken outputToken = new FeeOnTransferToken("Taxed", "TAX", 18, 1000);

        inputToken.mint(address(this), 100e18);
        inputToken.approve(address(hook.router()), type(uint256).max);

        (PoolKey memory customKey, PoolId customPoolId, bool zeroForOne) =
            _initCustomPool(address(inputToken), address(outputToken));

        hook.swap(customKey, zeroForOne, 10e18, ORDER_TICK, 0);

        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: customPoolId, swapper: address(this), tick: ORDER_TICK});
        uint256 expectedOut = hook.getBalanceOut(order, zeroForOne);

        address filler = makeAddr("taxedFiller");
        outputToken.mint(filler, expectedOut);
        vm.prank(filler);
        outputToken.approve(address(hook), type(uint256).max);

        uint256 swapperBefore = outputToken.balanceOf(address(this));

        vm.prank(filler);
        vm.expectRevert(AsyncSwap.INSUFFICIENT_OUTPUT_RECEIVED.selector);
        hook.fill(order, zeroForOne, expectedOut);

        assertEq(outputToken.balanceOf(address(this)), swapperBefore, "swapper should not receive partial output");
        assertEq(hook.getBalanceOut(order, zeroForOne), expectedOut, "order output should remain unchanged");
    }

    // ========================================
    // Cancel on wrong direction — should revert
    // ========================================

    function test_cancel_wrongDirection_reverts() public {
        uint256 swapAmount = 5e18;
        // Swap zeroForOne
        (AsyncSwap.Order memory order,) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        // Cancel with oneForZero — that direction was never populated
        vm.expectRevert(AsyncSwap.NOTHING_TO_CANCEL.selector);
        hook.cancelOrder(order, false);
    }

    function test_cancel_unknownPool_reverts() public {
        AsyncSwap.Order memory bogusOrder =
            AsyncSwap.Order({poolId: PoolId.wrap(bytes32(uint256(999))), swapper: address(this), tick: ORDER_TICK});

        vm.expectRevert(AsyncSwap.UNKNOWN_POOL.selector);
        hook.cancelOrder(bogusOrder, true);
    }

    function test_fill_paused_reverts_but_cancel_still_works() public {
        uint256 swapAmount = 10e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency1, expectedOut);

        hook.pause();

        vm.prank(filler);
        vm.expectRevert(IntentAuth.PAUSED.selector);
        hook.fill(order, true, expectedOut);

        uint256 balBefore = currency0.balanceOf(address(this));
        hook.cancelOrder(order, true);
        assertEq(currency0.balanceOf(address(this)) - balBefore, _netInput(swapAmount), "cancel should still work");
    }

    // ========================================
    // Fill on wrong direction — should revert
    // ========================================

    function test_fill_wrongDirection_reverts() public {
        uint256 swapAmount = 5e18;
        // Swap zeroForOne
        (AsyncSwap.Order memory order,) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        _setupFiller(filler, currency0, 1e18);

        // Fill with oneForZero — no order exists for that direction
        vm.prank(filler);
        vm.expectRevert(AsyncSwap.ORDER_ALREADY_FILLED.selector);
        hook.fill(order, false, 1e18);
    }

    // ========================================
    // Fill with no approval — ERC-20 transferFrom fails
    // ========================================

    function test_fill_noApproval_reverts() public {
        uint256 swapAmount = 5e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        // Mint tokens but do NOT approve the hook
        MockERC20(Currency.unwrap(currency1)).mint(filler, expectedOut);

        vm.prank(filler);
        vm.expectRevert();
        hook.fill(order, true, expectedOut);
    }

    // ========================================
    // Fill with insufficient balance — ERC-20 transferFrom fails
    // ========================================

    function test_fill_insufficientBalance_reverts() public {
        uint256 swapAmount = 5e18;
        (AsyncSwap.Order memory order, uint256 expectedOut) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        address filler = makeAddr("filler");
        // Approve but don't mint enough
        MockERC20(Currency.unwrap(currency1)).mint(filler, expectedOut - 1);
        vm.prank(filler);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.prank(filler);
        vm.expectRevert();
        hook.fill(order, true, expectedOut);
    }

    // ========================================
    // Double cancel reverts
    // ========================================

    function test_cancel_doubleCancel_reverts() public {
        uint256 swapAmount = 5e18;
        (AsyncSwap.Order memory order,) = _createSwapOrder(swapAmount, ORDER_TICK, true);

        hook.cancelOrder(order, true);

        vm.expectRevert(AsyncSwap.NOTHING_TO_CANCEL.selector);
        hook.cancelOrder(order, true);
    }

    // ========================================
    // Swap then cancel then swap again — storage cleared
    // ========================================

    function test_swapCancelSwap_storageCleared() public {
        uint256 swapAmount = 5e18;
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);

        // Swap
        _swap(true, swapAmount, ORDER_TICK, 0);
        assertEq(hook.getBalanceIn(order, true), _netInput(swapAmount));

        // Cancel
        hook.cancelOrder(order, true);
        assertEq(hook.getBalanceIn(order, true), 0);
        assertEq(hook.getBalanceOut(order, true), 0);

        // Swap again — should start fresh, not accumulate
        _swap(true, swapAmount, ORDER_TICK, 0);
        assertEq(hook.getBalanceIn(order, true), _netInput(swapAmount), "should be fresh after cancel");
    }
}

contract LyingTransferFromToken is MockERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        emit Transfer(from, to, 0);
        return true;
    }
}

contract FeeOnTransferToken is MockERC20 {
    uint256 internal immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_)
        MockERC20(name_, symbol_, decimals_)
    {
        feeBps = feeBps_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        uint256 fee = amount * feeBps / 10_000;
        uint256 received = amount - fee;

        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += received;
            totalSupply -= fee;
        }

        emit Transfer(from, to, received);
        if (fee > 0) emit Transfer(from, address(0), fee);
        return true;
    }
}
