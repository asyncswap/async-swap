// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

contract AsyncSwapTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    AsyncSwap hook;
    PoolKey poolKey;
    PoolId poolId;

    // Hook permission flags
    // beforeInitialize(13) | afterInitialize(12) | afterAddLiquidity(10) | beforeSwap(7) | beforeSwapReturnsDelta(3)
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint24 constant HOOK_FEE = 1_2000; // 1.2% in ppm
    int24 constant TICK_SPACING = 240; // fee / 100 * 2 = 12000/100*2
    int24 constant ORDER_TICK = 0; // price = 1.0 for simplicity

    function setUp() public {
        // Deploy manager and all test routers
        deployFreshManagerAndRouters();

        // Deploy tokens and approve routers
        deployMintAndApprove2Currencies();

        // Deploy hook at the flag-aligned address — constructor runs, deploys router
        address hookAddr = address(HOOK_FLAGS);
        deployCodeTo("AsyncSwap.sol:AsyncSwap", abi.encode(address(manager), address(this)), hookAddr);
        hook = AsyncSwap(hookAddr);

        // Approve router for settle (CurrencySettler.transferFrom is called by router as msg.sender)
        address routerAddr = address(hook.router());
        MockERC20(Currency.unwrap(currency0)).approve(routerAddr, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(routerAddr, type(uint256).max);

        // Initialize pool: the hook's beforeInitialize requires sender == owner (address(this))
        // and key.fee >= 12000
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        poolId = poolKey.toId();

        // Initialize at price = 1:1 (tick 0)
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    // ========================================
    // Helper: build Order struct for hookData
    // ========================================

    function _makeOrder(address swapper, int24 tick) internal view returns (AsyncSwap.Order memory) {
        return AsyncSwap.Order({poolId: poolId, swapper: swapper, tick: tick});
    }

    // ========================================
    // Helper: execute a swap through the hook
    // ========================================

    function _swap(bool zeroForOne, uint256 amountIn, int24 tick, uint256 minAmountOut) internal {
        hook.swap(poolKey, zeroForOne, amountIn, tick, minAmountOut);
    }

    function _netInput(uint256 amount) internal pure returns (uint256) {
        uint256 fee = FullMath.mulDivRoundingUp(amount, HOOK_FEE, 1_000_000);
        return amount - fee;
    }

    // ========================================
    // Test: setUp deploys and initializes correctly
    // ========================================

    function test_setUp_hookDeployed() public view {
        assertEq(address(hook.POOL_MANAGER()), address(manager));
        assertEq(hook.protocolOwner(), address(this));
        assertTrue(address(hook.router()) != address(0), "router should be deployed");
    }

    function test_setUp_poolInitialized() public view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
    }

    // ========================================
    // Test: noOp — AMM pool state unchanged
    // ========================================

    function test_exactInput_noOpSwap_poolStateUnchanged() public {
        // Record pool state before
        (uint160 sqrtPriceBefore, int24 tickBefore,,) = manager.getSlot0(poolId);
        uint128 liquidityBefore = manager.getLiquidity(poolId);

        // Execute swap: exact input 1e18, zeroForOne, at tick 0 (price=1)
        uint256 swapAmount = 1e18;
        _swap(true, swapAmount, ORDER_TICK, 0);

        // Pool state should be unchanged (noOp)
        (uint160 sqrtPriceAfter, int24 tickAfter,,) = manager.getSlot0(poolId);
        uint128 liquidityAfter = manager.getLiquidity(poolId);

        assertEq(sqrtPriceAfter, sqrtPriceBefore, "sqrtPrice changed - AMM was not noOp'd");
        assertEq(tickAfter, tickBefore, "tick changed - AMM was not noOp'd");
        assertEq(liquidityAfter, liquidityBefore, "liquidity changed - AMM was not noOp'd");
    }

    function test_exactInput_noOpSwap_oneForZero_poolStateUnchanged() public {
        (uint160 sqrtPriceBefore, int24 tickBefore,,) = manager.getSlot0(poolId);

        uint256 swapAmount = 1e18;
        _swap(false, swapAmount, ORDER_TICK, 0);

        (uint160 sqrtPriceAfter, int24 tickAfter,,) = manager.getSlot0(poolId);
        assertEq(sqrtPriceAfter, sqrtPriceBefore, "sqrtPrice changed - AMM was not noOp'd");
        assertEq(tickAfter, tickBefore, "tick changed - AMM was not noOp'd");
    }

    // ========================================
    // Test: deltas net to zero (tx doesn't revert)
    // ========================================

    function test_exactInput_deltasNetToZero_zeroForOne() public {
        uint256 swapAmount = 5e18;

        uint256 bal0Before = currency0.balanceOf(address(this));
        _swap(true, swapAmount, ORDER_TICK, 0);
        uint256 bal0After = currency0.balanceOf(address(this));

        // User (this contract) should have paid exactly swapAmount of currency0
        assertEq(bal0Before - bal0After, swapAmount, "user did not pay exact input amount");
    }

    function test_exactInput_deltasNetToZero_oneForZero() public {
        uint256 swapAmount = 5e18;

        uint256 bal1Before = currency1.balanceOf(address(this));
        _swap(false, swapAmount, ORDER_TICK, 0);
        uint256 bal1After = currency1.balanceOf(address(this));

        assertEq(bal1Before - bal1After, swapAmount, "user did not pay exact input amount");
    }

    // ========================================
    // Test: fee is deducted from input, output computed from remainder
    // ========================================

    function test_exactInput_feeDeducted_amountOutCorrect_zeroForOne() public {
        // At tick 0, price = 1. sqrtPriceX96 = SQRT_PRICE_1_1
        // amountIn = 1e18
        // feeAmount = ceil(1e18 * 12000 / 1_000_000) = ceil(12e15) = 12000000000000000
        // amountInAfterFee = 1e18 - 12e15 = 988000000000000000
        // amountOut = mulDiv(mulDiv(988e15, sqrtP, Q96), sqrtP, Q96)
        // At price=1 (sqrtP = Q96), this simplifies to 988e15

        uint256 swapAmount = 1e18;
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        _swap(true, swapAmount, ORDER_TICK, 0);

        uint256 balanceOut = hook.getBalanceOut(order, true);
        uint256 balanceIn = hook.getBalanceIn(order, true);

        assertEq(balanceIn, _netInput(swapAmount), "balanceIn should equal net input");

        // Expected: 1e18 - 1.2% fee = 988e15, then at price=1 output = 988e15
        uint256 expectedFee = FullMath.mulDivRoundingUp(swapAmount, HOOK_FEE, 1_000_000);
        uint256 expectedAmountInAfterFee = swapAmount - expectedFee;

        // At tick 0, sqrtPriceX96 = SQRT_PRICE_1_1
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(ORDER_TICK);
        uint256 expectedOut = FullMath.mulDiv(
            FullMath.mulDiv(expectedAmountInAfterFee, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96
        );

        assertEq(balanceOut, expectedOut, "amountOut mismatch");
        // At price=1, amountOut should be very close to amountInAfterFee
        assertApproxEqRel(balanceOut, expectedAmountInAfterFee, 1e14, "amountOut should be ~98.8% of input at price=1");
    }

    function test_exactInput_feeDeducted_oneForZero() public {
        uint256 swapAmount = 1e18;
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        _swap(false, swapAmount, ORDER_TICK, 0);

        uint256 balanceOut = hook.getBalanceOut(order, false);
        uint256 balanceIn = hook.getBalanceIn(order, false);

        assertEq(balanceIn, _netInput(swapAmount), "balanceIn should equal net input");

        uint256 expectedFee = FullMath.mulDivRoundingUp(swapAmount, HOOK_FEE, 1_000_000);
        uint256 expectedAmountInAfterFee = swapAmount - expectedFee;

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(ORDER_TICK);
        uint256 expectedOut = FullMath.mulDiv(
            FullMath.mulDiv(expectedAmountInAfterFee, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice
        );

        assertEq(balanceOut, expectedOut, "amountOut mismatch");
        assertApproxEqRel(balanceOut, expectedAmountInAfterFee, 1e14, "amountOut should be ~98.8% of input at price=1");
    }

    // ========================================
    // Test: fee at a non-1:1 price (tick != 0)
    // ========================================

    function test_exactInput_nonUnityPrice_zeroForOne() public {
        // Use tick 46054 ~ price 100
        // Selling 1 token0 should yield ~98.8 token1 (after 1.2% fee)
        int24 tick = 46054;
        uint256 swapAmount = 1e18;
        AsyncSwap.Order memory order = _makeOrder(address(this), tick);
        _swap(true, swapAmount, tick, 0);

        uint256 balanceOut = hook.getBalanceOut(order, true);

        // Compute expected
        uint256 expectedFee = FullMath.mulDivRoundingUp(swapAmount, HOOK_FEE, 1_000_000);
        uint256 amountInAfterFee = swapAmount - expectedFee;
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        uint256 expectedOut = FullMath.mulDiv(
            FullMath.mulDiv(amountInAfterFee, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96
        );

        assertEq(balanceOut, expectedOut, "amountOut mismatch at tick 46054");
        // price ~100, after 1.2% fee from 1e18, net input ~0.988e18
        // output should be ~98.8e18
        assertGt(balanceOut, 98e18, "output should be > 98 tokens at price ~100");
        assertLt(balanceOut, 100e18, "output should be < 100 tokens (fee deducted)");
    }

    // ========================================
    // Test: slippage protection
    // ========================================

    function test_exactInput_slippageReverts() public {
        // At tick 0 price=1, 1e18 input with 1.2% fee -> ~988e15 output
        // Setting minAmountOut = 999e15 should revert
        uint256 swapAmount = 1e18;

        // PoolManager wraps hook reverts in WrappedError
        vm.expectRevert();
        _swap(true, swapAmount, ORDER_TICK, 999e15);
    }

    function test_exactInput_slippagePasses() public {
        // Setting minAmountOut = 980e15 should pass (output is ~988e15)
        uint256 swapAmount = 1e18;
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);

        // Should not revert
        _swap(true, swapAmount, ORDER_TICK, 980e15);

        uint256 balanceOut = hook.getBalanceOut(order, true);
        assertGe(balanceOut, 980e15, "output below slippage floor");
    }

    function test_exactInput_slippage_exactBoundary() public {
        // Compute exact expected output, use it as minAmountOut — should pass
        uint256 swapAmount = 1e18;
        uint256 expectedFee = FullMath.mulDivRoundingUp(swapAmount, HOOK_FEE, 1_000_000);
        uint256 amountInAfterFee = swapAmount - expectedFee;
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(ORDER_TICK);
        uint256 exactOutput = FullMath.mulDiv(
            FullMath.mulDiv(amountInAfterFee, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96
        );

        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        _swap(true, swapAmount, ORDER_TICK, exactOutput);

        assertEq(hook.getBalanceOut(order, true), exactOutput);
    }

    // ========================================
    // Test: order state recorded correctly
    // ========================================

    function test_exactInput_orderStateRecorded() public {
        uint256 swapAmount = 2e18;
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        _swap(true, swapAmount, ORDER_TICK, 0);

        uint256 balanceIn = hook.getBalanceIn(order, true);
        uint256 balanceOut = hook.getBalanceOut(order, true);

        assertEq(balanceIn, _netInput(swapAmount), "balanceIn not recorded");
        assertGt(balanceOut, 0, "balanceOut not recorded");
    }

    function test_exactInput_multipleOrdersAccumulate() public {
        uint256 swapAmount = 1e18;
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);

        // First swap
        _swap(true, swapAmount, ORDER_TICK, 0);
        uint256 balanceIn1 = hook.getBalanceIn(order, true);
        uint256 balanceOut1 = hook.getBalanceOut(order, true);

        // Second swap with same order params
        _swap(true, swapAmount, ORDER_TICK, 0);
        uint256 balanceIn2 = hook.getBalanceIn(order, true);
        uint256 balanceOut2 = hook.getBalanceOut(order, true);

        // Should accumulate (+=)
        assertEq(balanceIn2, balanceIn1 * 2, "balancesIn should accumulate");
        assertEq(balanceOut2, balanceOut1 * 2, "balancesOut should accumulate");
    }

    function test_exactInput_differentDirections_independentState() public {
        uint256 swapAmount = 1e18;
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);

        _swap(true, swapAmount, ORDER_TICK, 0);
        _swap(false, swapAmount, ORDER_TICK, 0);

        uint256 balanceInZFO = hook.getBalanceIn(order, true);
        uint256 balanceInOFZ = hook.getBalanceIn(order, false);

        // Both should be recorded independently
        assertEq(balanceInZFO, _netInput(swapAmount), "zeroForOne balanceIn");
        assertEq(balanceInOFZ, _netInput(swapAmount), "oneForZero balanceIn");
    }

    // ========================================
    // Test: Swap event emitted
    // ========================================

    function test_exactInput_emitsSwapEvent() public {
        uint256 swapAmount = 1e18;
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        bytes32 expectedOrderId = keccak256(abi.encode(order));

        vm.expectEmit(true, false, false, false, address(hook));
        emit AsyncSwap.Swap(expectedOrderId, order);

        _swap(true, swapAmount, ORDER_TICK, 0);
    }

    // ========================================
    // Test: untrusted caller reverts
    // ========================================

    function test_untrustedCaller_reverts() public {
        // Any contract calling PM.swap directly (not through hook.swap) should be rejected
        PoolSwapTest externalRouter = new PoolSwapTest(manager);

        MockERC20(Currency.unwrap(currency0)).approve(address(externalRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(externalRouter), type(uint256).max);

        uint256 swapAmount = 1e18;
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);

        // beforeSwap checks sender == address(this), so external callers revert
        vm.expectRevert();
        externalRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(order, uint256(0))
        );
    }

    // ========================================
    // Test: hook claim tokens minted to hook
    // ========================================

    function test_exactInput_hookReceivesClaimTokens() public {
        uint256 swapAmount = 1e18;

        // Check hook's ERC-6909 claim balance before
        uint256 claimsBefore = manager.balanceOf(address(hook), currency0.toId());

        _swap(true, swapAmount, ORDER_TICK, 0);

        // Hook should have received claim tokens for the full input
        uint256 claimsAfter = manager.balanceOf(address(hook), currency0.toId());
        assertEq(claimsAfter - claimsBefore, swapAmount, "hook did not receive correct claim tokens");
    }

    // ========================================
    // Test: various swap amounts
    // ========================================

    function test_exactInput_smallAmount() public {
        uint256 swapAmount = 1000; // very small
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        _swap(true, swapAmount, ORDER_TICK, 0);

        uint256 balanceIn = hook.getBalanceIn(order, true);
        assertEq(balanceIn, _netInput(swapAmount));
    }

    function test_exactInput_largeAmount() public {
        uint256 swapAmount = 100_000e18; // large
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        _swap(true, swapAmount, ORDER_TICK, 0);

        uint256 balanceIn = hook.getBalanceIn(order, true);
        assertEq(balanceIn, _netInput(swapAmount));

        uint256 balanceOut = hook.getBalanceOut(order, true);
        // After 1.2% fee, output should be ~98.8% of input at price=1
        assertApproxEqRel(balanceOut, swapAmount * 988_000 / 1_000_000, 1e14);
    }

    // ========================================
    // Test: hook address has correct permission flags
    // ========================================

    function test_hookAddress_hasCorrectFlags() public view {
        uint160 addr = uint160(address(hook));
        assertTrue(addr & Hooks.BEFORE_INITIALIZE_FLAG != 0, "missing BEFORE_INITIALIZE");
        assertTrue(addr & Hooks.AFTER_INITIALIZE_FLAG != 0, "missing AFTER_INITIALIZE");
        assertTrue(addr & Hooks.AFTER_ADD_LIQUIDITY_FLAG != 0, "missing AFTER_ADD_LIQUIDITY");
        assertTrue(addr & Hooks.BEFORE_SWAP_FLAG != 0, "missing BEFORE_SWAP");
        assertTrue(addr & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0, "missing BEFORE_SWAP_RETURNS_DELTA");
    }

    // ================================================================
    //                        FUZZ TESTS
    // ================================================================

    // ----------------------------------------
    // Fuzz: fee always rounds UP (protocol never loses)
    // ----------------------------------------

    function testFuzz_feeRoundsUp_protocolNeverLoses(uint256 amountIn) public pure {
        // Bound to realistic range: 1 wei to 100M tokens
        amountIn = bound(amountIn, 1, 100_000_000e18);

        uint256 fee = FullMath.mulDivRoundingUp(amountIn, HOOK_FEE, 1_000_000);

        // Fee must never be zero unless amountIn is zero
        if (amountIn > 0) {
            assertGt(fee, 0, "fee must be > 0 for any nonzero input");
        }

        // Fee must be >= the exact mathematical value: amountIn * 12000 / 1_000_000
        // i.e. fee * 1_000_000 >= amountIn * 12000
        assertGe(fee * 1_000_000, amountIn * HOOK_FEE, "fee rounds down - protocol loses");

        // Fee must not overshoot by more than 1 wei vs the exact value
        // exact = ceil(amountIn * 12000 / 1_000_000)
        // fee - floor(amountIn * 12000 / 1_000_000) <= 1
        uint256 floorFee = (amountIn * HOOK_FEE) / 1_000_000;
        assertLe(fee - floorFee, 1, "fee overcharged by more than 1 wei");
    }

    // ----------------------------------------
    // Fuzz: output rounds DOWN (user never gets extra)
    // ----------------------------------------

    function testFuzz_outputRoundsDown_userNeverGetsExtra(uint256 amountIn, int24 tick, bool zeroForOne) public pure {
        // Bound tick to valid TickMath range
        tick = int24(bound(int256(tick), -887272, 887272));
        // Bound amount to range where mulDiv won't revert from result overflow
        amountIn = bound(amountIn, 1, 100_000_000e18);

        uint256 fee = FullMath.mulDivRoundingUp(amountIn, HOOK_FEE, 1_000_000);
        if (fee >= amountIn) return; // degenerate: fee eats everything

        uint256 amountInAfterFee = amountIn - fee;
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);

        // Compute output the same way the contract does (mulDiv rounds down)
        uint256 amountOut;
        // Compute upper bound using mulDivRoundingUp (ceiling of each step)
        uint256 amountOutCeil;
        if (zeroForOne) {
            amountOut = FullMath.mulDiv(
                FullMath.mulDiv(amountInAfterFee, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96
            );
            amountOutCeil = FullMath.mulDivRoundingUp(
                FullMath.mulDivRoundingUp(amountInAfterFee, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96
            );
        } else {
            amountOut = FullMath.mulDiv(
                FullMath.mulDiv(amountInAfterFee, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice
            );
            amountOutCeil = FullMath.mulDivRoundingUp(
                FullMath.mulDivRoundingUp(amountInAfterFee, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice
            );
        }

        // Invariant 1: floor output <= ceiling output (sanity)
        assertLe(amountOut, amountOutCeil, "floor exceeds ceiling - impossible");

        // Invariant 2: reverse round-trip must not exceed original input.
        // Convert output back to input numeraire using the inverse price direction.
        // If round-tripped value > original net input, the user could profit from rounding.
        // This is the real security property: mulDiv truncation never favors the user.
        uint256 reverseInput;
        if (zeroForOne) {
            // output is in token1. Convert back: token1 -> token0 = divide by price
            reverseInput =
                FullMath.mulDiv(FullMath.mulDiv(amountOut, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice);
        } else {
            // output is in token0. Convert back: token0 -> token1 = multiply by price
            reverseInput =
                FullMath.mulDiv(FullMath.mulDiv(amountOut, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96);
        }
        assertLe(reverseInput, amountInAfterFee, "round-trip exceeds input - user profits from rounding");

        // Invariant 3: ceiling round-trip must be close to original input.
        // Using mulDivRoundingUp for the reverse gives an upper bound on the true value.
        // This upper bound should be >= the original input (proves the floor output
        // is a genuine underestimate, not a catastrophic truncation).
        if (amountOutCeil > 0) {
            uint256 reverseCeil;
            if (zeroForOne) {
                reverseCeil = FullMath.mulDivRoundingUp(
                    FullMath.mulDivRoundingUp(amountOutCeil, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice
                );
            } else {
                reverseCeil = FullMath.mulDivRoundingUp(
                    FullMath.mulDivRoundingUp(amountOutCeil, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96
                );
            }
            // The ceiling reverse should bracket the original input from above
            assertGe(reverseCeil, amountInAfterFee, "ceiling reverse below input - conversion is lossy beyond rounding");
        }
    }

    // ----------------------------------------
    // Fuzz: full swap — deltas net to zero, order state correct, pool unchanged
    // ----------------------------------------

    function testFuzz_swap_invariants(uint256 amountIn, int24 tick, bool zeroForOne) public {
        // Bound tick to valid range
        tick = int24(bound(int256(tick), -887272, 887272));
        // Bound amount: must be > 0 and fit in int256, also capped to token balance
        amountIn = bound(amountIn, 1, 2 ** 100);

        // Pre-compute expected fee and output. Skip if fee >= amountIn (degenerate).
        uint256 fee = FullMath.mulDivRoundingUp(amountIn, HOOK_FEE, 1_000_000);
        if (fee >= amountIn) return;

        // Pre-check: will _computeAmountOut overflow in mulDiv?
        uint256 expectedOut;
        try this.computeAmountOutExternal(amountIn - fee, tick, zeroForOne) returns (uint256 out) {
            expectedOut = out;
        } catch {
            return; // mulDiv overflow at extreme tick/amount
        }

        // At extreme ticks the price can be so low that output rounds to 0 — skip
        if (expectedOut == 0) return;

        _assertSwapInvariants(amountIn, tick, zeroForOne, expectedOut);
    }

    function _assertSwapInvariants(uint256 amountIn, int24 tick, bool zeroForOne, uint256 expectedOut) internal {
        // Record state before
        (uint160 sqrtPriceBefore, int24 tickBefore,,) = manager.getSlot0(poolId);
        Currency inputCurrency = zeroForOne ? currency0 : currency1;
        uint256 userBalBefore = inputCurrency.balanceOf(address(this));
        uint256 hookClaimsBefore = manager.balanceOf(address(hook), inputCurrency.toId());

        // Execute swap
        AsyncSwap.Order memory order = _makeOrder(address(this), tick);
        _swap(zeroForOne, amountIn, tick, 0);

        // Invariant 1: Pool state unchanged (no-op)
        (uint160 sqrtPriceAfter, int24 tickAfter,,) = manager.getSlot0(poolId);
        assertEq(sqrtPriceAfter, sqrtPriceBefore, "fuzz: sqrtPrice changed");
        assertEq(tickAfter, tickBefore, "fuzz: tick changed");

        // Invariant 2: User paid exactly amountIn
        assertEq(userBalBefore - inputCurrency.balanceOf(address(this)), amountIn, "fuzz: user paid wrong amount");

        // Invariant 3: Hook received claim tokens for full input
        uint256 hookClaimsAfter = manager.balanceOf(address(hook), inputCurrency.toId());
        assertEq(hookClaimsAfter - hookClaimsBefore, amountIn, "fuzz: hook claims mismatch");

        // Invariant 4: Order state recorded correctly
        assertEq(hook.getBalanceIn(order, zeroForOne), _netInput(amountIn), "fuzz: balanceIn mismatch");
        assertEq(hook.getBalanceOut(order, zeroForOne), expectedOut, "fuzz: balanceOut mismatch");

        // Invariant 5: Output > 0 for nonzero input
        assertGt(hook.getBalanceOut(order, zeroForOne), 0, "fuzz: zero output for nonzero input");
    }

    /// @dev External wrapper so we can use try/catch on a pure computation
    function computeAmountOutExternal(uint256 amountInAfterFee, int24 tick, bool zeroForOne)
        external
        pure
        returns (uint256)
    {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        if (zeroForOne) {
            return FullMath.mulDiv(
                FullMath.mulDiv(amountInAfterFee, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96
            );
        } else {
            return FullMath.mulDiv(
                FullMath.mulDiv(amountInAfterFee, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice
            );
        }
    }

    // ----------------------------------------
    // Fuzz: slippage protection — setting minOut above actual output always reverts
    // ----------------------------------------

    function testFuzz_slippage_reverts_when_minOut_too_high(uint256 amountIn, int24 tick, bool zeroForOne) public {
        tick = int24(bound(int256(tick), -887272, 887272));
        amountIn = bound(amountIn, 1000, 2 ** 100); // need enough for fee to leave something

        uint256 fee = FullMath.mulDivRoundingUp(amountIn, HOOK_FEE, 1_000_000);
        if (fee >= amountIn) return;

        // Compute what the output would be
        try this.computeAmountOutExternal(amountIn - fee, tick, zeroForOne) returns (uint256 expectedOut) {
            if (expectedOut == 0) return; // can't set minOut above 0 meaningfully
            // Set minAmountOut 1 wei above actual — must revert
            vm.expectRevert();
            _swap(zeroForOne, amountIn, tick, expectedOut + 1);
        } catch {
            return; // overflow in computation, skip
        }
    }

    // ----------------------------------------
    // Fuzz: slippage protection — setting minOut at or below actual output passes
    // ----------------------------------------

    function testFuzz_slippage_passes_when_minOut_at_or_below(uint256 amountIn, int24 tick, bool zeroForOne) public {
        tick = int24(bound(int256(tick), -887272, 887272));
        amountIn = bound(amountIn, 1000, 2 ** 100);

        uint256 fee = FullMath.mulDivRoundingUp(amountIn, HOOK_FEE, 1_000_000);
        if (fee >= amountIn) return;

        try this.computeAmountOutExternal(amountIn - fee, tick, zeroForOne) returns (uint256 expectedOut) {
            if (expectedOut == 0) return;

            AsyncSwap.Order memory order = _makeOrder(address(this), tick);
            _swap(zeroForOne, amountIn, tick, expectedOut);

            uint256 balanceOut = hook.getBalanceOut(order, zeroForOne);
            assertGe(balanceOut, expectedOut, "fuzz: output below slippage floor");
        } catch {
            return;
        }
    }

    // ----------------------------------------
    // Fuzz: order accumulation — same order params, multiple swaps
    // ----------------------------------------

    function testFuzz_orderAccumulation(uint256 amount1, uint256 amount2, bool zeroForOne) public {
        amount1 = bound(amount1, 1000, 2 ** 99);
        amount2 = bound(amount2, 1000, 2 ** 99);

        uint256 net1 = _netInput(amount1);
        uint256 net2 = _netInput(amount2);

        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);

        // First swap
        _swap(zeroForOne, amount1, ORDER_TICK, 0);
        uint256 balIn1 = hook.getBalanceIn(order, zeroForOne);
        uint256 balOut1 = hook.getBalanceOut(order, zeroForOne);

        // Second swap
        _swap(zeroForOne, amount2, ORDER_TICK, 0);
        uint256 balIn2 = hook.getBalanceIn(order, zeroForOne);
        uint256 balOut2 = hook.getBalanceOut(order, zeroForOne);

        // Compute expected output for each individually
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(ORDER_TICK);

        uint256 out1;
        uint256 out2;
        if (zeroForOne) {
            out1 = FullMath.mulDiv(FullMath.mulDiv(net1, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96);
            out2 = FullMath.mulDiv(FullMath.mulDiv(net2, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96);
        } else {
            out1 = FullMath.mulDiv(FullMath.mulDiv(net1, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice);
            out2 = FullMath.mulDiv(FullMath.mulDiv(net2, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice);
        }

        // Balances should accumulate additively
        assertEq(balIn2, net1 + net2, "fuzz: balanceIn not additive");
        assertEq(balOut2, out1 + out2, "fuzz: balanceOut not additive");

        // First swap should have been recorded independently
        assertEq(balIn1, net1, "fuzz: first balanceIn wrong");
        assertEq(balOut1, out1, "fuzz: first balanceOut wrong");
    }

    // ----------------------------------------
    // Fuzz: negative ticks (price < 1) — both directions
    // ----------------------------------------

    function testFuzz_negativeTick_zeroForOne(uint256 amountIn, int24 tick) public {
        // Only negative ticks (sqrtPrice ratio < 1 in raw terms)
        tick = int24(bound(int256(tick), -887272, -1));
        amountIn = bound(amountIn, 1000, 2 ** 100);

        uint256 fee = FullMath.mulDivRoundingUp(amountIn, HOOK_FEE, 1_000_000);
        if (fee >= amountIn) return;

        try this.computeAmountOutExternal(amountIn - fee, tick, true) returns (uint256 expectedOut) {
            if (expectedOut == 0) return;

            AsyncSwap.Order memory order = _makeOrder(address(this), tick);
            _swap(true, amountIn, tick, 0);

            uint256 balanceOut = hook.getBalanceOut(order, true);
            assertEq(balanceOut, expectedOut, "fuzz: negative tick zfo output mismatch");
            assertGt(balanceOut, 0, "fuzz: zero output for nonzero input");
        } catch {
            return;
        }
    }

    function testFuzz_negativeTick_oneForZero(uint256 amountIn, int24 tick) public {
        // Only negative ticks (sqrtPrice ratio < 1 in raw terms)
        tick = int24(bound(int256(tick), -887272, -1));
        amountIn = bound(amountIn, 1000, 2 ** 100);

        uint256 fee = FullMath.mulDivRoundingUp(amountIn, HOOK_FEE, 1_000_000);
        if (fee >= amountIn) return;

        try this.computeAmountOutExternal(amountIn - fee, tick, false) returns (uint256 expectedOut) {
            if (expectedOut == 0) return;

            AsyncSwap.Order memory order = _makeOrder(address(this), tick);
            _swap(false, amountIn, tick, 0);

            uint256 balanceOut = hook.getBalanceOut(order, false);
            assertEq(balanceOut, expectedOut, "fuzz: negative tick ofz output mismatch");
            assertGt(balanceOut, 0, "fuzz: zero output for nonzero input");
        } catch {
            return;
        }
    }

    // ----------------------------------------
    // Fuzz: price symmetry — zfo at tick T and ofz at tick -T produce reciprocal outputs
    // ----------------------------------------

    function testFuzz_priceSymmetry(uint256 amountIn, int24 tick) public pure {
        // Positive ticks only (we mirror to -tick). Exclude 0 — no price conversion there.
        tick = int24(bound(int256(tick), 1, 400000)); // cap to avoid overflow in large-price mulDiv
        amountIn = bound(amountIn, 1e15, 1e22); // moderate range to keep intermediates in range

        uint256 fee = FullMath.mulDivRoundingUp(amountIn, HOOK_FEE, 1_000_000);
        if (fee >= amountIn) return;
        uint256 netInput = amountIn - fee;

        uint160 sqrtPricePos = TickMath.getSqrtPriceAtTick(tick);
        uint160 sqrtPriceNeg = TickMath.getSqrtPriceAtTick(-tick);

        // zfo at tick T: output = netInput * price(T)
        uint256 outZfoAtT =
            FullMath.mulDiv(FullMath.mulDiv(netInput, sqrtPricePos, FixedPoint96.Q96), sqrtPricePos, FixedPoint96.Q96);

        // ofz at tick -T: output = netInput / price(-T) = netInput * price(T)
        // because price(-T) = 1/price(T), so 1/price(-T) = price(T)
        uint256 outOfzAtNegT =
            FullMath.mulDiv(FullMath.mulDiv(netInput, FixedPoint96.Q96, sqrtPriceNeg), FixedPoint96.Q96, sqrtPriceNeg);

        // Both outputs represent netInput * price(T) computed via different sqrtPrice paths.
        // mulDiv rounding can differ. Use relative tolerance: diff / max(outputs) < 1e-12
        if (outZfoAtT == 0 && outOfzAtNegT == 0) return;

        uint256 diff = outZfoAtT > outOfzAtNegT ? outZfoAtT - outOfzAtNegT : outOfzAtNegT - outZfoAtT;
        uint256 maxOut = outZfoAtT > outOfzAtNegT ? outZfoAtT : outOfzAtNegT;

        // Allow up to 1 bps relative error (very generous for mulDiv rounding)
        assertLe(diff * 1e18 / maxOut, 1e14, "fuzz: price symmetry violated beyond rounding tolerance");
    }

    // ----------------------------------------
    // Test: zero amount reverts
    // ----------------------------------------

    function test_zeroAmount_reverts() public {
        vm.expectRevert("ZERO_AMOUNT");
        hook.swap(poolKey, true, 0, ORDER_TICK, 0);
    }

    // ----------------------------------------
    // Fuzz: beforeInitialize — non-owner always reverts
    // ----------------------------------------

    function testFuzz_beforeInitialize_nonOwnerReverts(address caller) public {
        vm.assume(caller != address(this)); // address(this) is the owner
        vm.assume(caller != address(0)); // avoid zero-address edge cases

        // Deploy fresh tokens so we get an uninitialized pool (avoids PoolAlreadyInitialized)
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        PoolKey memory freshKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Non-owner caller should revert with "NOT HOOK OWNER" (wrapped by PoolManager)
        vm.prank(caller);
        vm.expectRevert();
        manager.initialize(freshKey, SQRT_PRICE_1_1);

        // Verify the owner CAN initialize the same pool
        manager.initialize(freshKey, SQRT_PRICE_1_1);
    }

    // ----------------------------------------
    // Fuzz: beforeInitialize — fee below minimum reverts
    // ----------------------------------------

    function testFuzz_beforeInitialize_nonDynamicFeeReverts(uint24 badFee) public {
        // Any fee that is NOT DYNAMIC_FEE_FLAG should revert
        vm.assume(badFee != LPFeeLibrary.DYNAMIC_FEE_FLAG);

        // Deploy fresh tokens so we get an uninitialized pool
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        PoolKey memory freshKey = PoolKey({
            currency0: c0, currency1: c1, fee: badFee, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });

        // Should revert with "USE DYNAMIC FEE" (wrapped by PoolManager)
        vm.expectRevert();
        manager.initialize(freshKey, SQRT_PRICE_1_1);
    }
}
