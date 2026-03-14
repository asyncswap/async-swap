// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {AsyncRouter} from "../src/AsyncRouter.sol";
import {IntentAuth} from "../src/IntentAuth.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

contract AsyncSwapNativeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AsyncSwap hook;
    PoolKey poolKey;
    PoolId poolId;
    MockERC20 token1;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint24 constant HOOK_FEE = 1_2000;
    int24 constant TICK_SPACING = 240;
    int24 constant ORDER_TICK = 0;

    address alice = makeAddr("alice");
    address filler = makeAddr("filler");

    function setUp() public {
        deployFreshManagerAndRouters();

        address hookAddr = address(HOOK_FLAGS);
        deployCodeTo("AsyncSwap.sol:AsyncSwap", abi.encode(address(manager), address(this)), hookAddr);
        hook = AsyncSwap(hookAddr);

        token1 = new MockERC20("Token One", "TK1", 18);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        vm.deal(alice, 100 ether);
        vm.deal(filler, 100 ether);
        token1.mint(alice, 100e18);
        token1.mint(filler, 100e18);

        address hookRouter = address(hook.router());

        vm.prank(alice);
        token1.approve(hookRouter, type(uint256).max);

        vm.prank(filler);
        token1.approve(address(hook), type(uint256).max);
    }

    function _order(address swapper, int24 tick) internal view returns (AsyncSwap.Order memory) {
        return AsyncSwap.Order({poolId: poolId, swapper: swapper, tick: tick});
    }

    function _netInput(uint256 amount) internal pure returns (uint256) {
        uint256 fee = FullMath.mulDivRoundingUp(amount, HOOK_FEE, 1_000_000);
        return amount - fee;
    }

    function test_nativeInput_swap_records_order_and_claims() public {
        uint256 amountIn = 1 ether;

        vm.prank(alice);
        hook.swap{value: amountIn}(poolKey, true, amountIn, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order = _order(alice, ORDER_TICK);

        assertEq(hook.getBalanceIn(order, true), _netInput(amountIn), "input not recorded");
        assertGt(hook.getBalanceOut(order, true), 0, "output not recorded");
        assertEq(manager.balanceOf(address(hook), poolKey.currency0.toId()), amountIn, "native claim not minted");
    }

    function test_nativeInput_fill_fullFill() public {
        uint256 amountIn = 1 ether;

        vm.prank(alice);
        hook.swap{value: amountIn}(poolKey, true, amountIn, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order = _order(alice, ORDER_TICK);
        uint256 expectedOut = hook.getBalanceOut(order, true);

        uint256 aliceTokenBefore = token1.balanceOf(alice);
        uint256 fillerClaimsBefore = manager.balanceOf(filler, poolKey.currency0.toId());

        vm.prank(filler);
        hook.fill(order, true, expectedOut);

        assertEq(token1.balanceOf(alice) - aliceTokenBefore, expectedOut, "alice did not receive output");
        assertEq(
            manager.balanceOf(filler, poolKey.currency0.toId()) - fillerClaimsBefore,
            _netInput(amountIn),
            "filler claims wrong"
        );
        assertEq(hook.getBalanceIn(order, true), 0, "remaining input should be zero");
        assertEq(hook.getBalanceOut(order, true), 0, "remaining output should be zero");
    }

    function test_nativeOutput_fill_fullFill() public {
        uint256 amountIn = 1e18;

        vm.prank(alice);
        hook.swap(poolKey, false, amountIn, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order = _order(alice, ORDER_TICK);
        uint256 expectedOut = hook.getBalanceOut(order, false);

        uint256 aliceEthBefore = alice.balance;
        uint256 fillerClaimsBefore = manager.balanceOf(filler, poolKey.currency1.toId());

        vm.prank(filler);
        hook.fill{value: expectedOut}(order, false, expectedOut);

        assertEq(alice.balance - aliceEthBefore, expectedOut, "alice did not receive native output");
        assertEq(
            manager.balanceOf(filler, poolKey.currency1.toId()) - fillerClaimsBefore,
            _netInput(amountIn),
            "filler claims wrong"
        );
        assertEq(hook.getBalanceIn(order, false), 0, "remaining input should be zero");
        assertEq(hook.getBalanceOut(order, false), 0, "remaining output should be zero");
    }

    function test_nativeOutput_partialFill() public {
        uint256 amountIn = 1e18;

        vm.prank(alice);
        hook.swap(poolKey, false, amountIn, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order = _order(alice, ORDER_TICK);
        uint256 remainingOutBefore = hook.getBalanceOut(order, false);
        uint256 remainingInBefore = hook.getBalanceIn(order, false);
        uint256 fillAmount = remainingOutBefore / 2;
        uint256 aliceEthBefore = alice.balance;
        uint256 fillerClaimsBefore = manager.balanceOf(filler, poolKey.currency1.toId());

        vm.prank(filler);
        hook.fill{value: fillAmount}(order, false, fillAmount);

        assertEq(alice.balance - aliceEthBefore, fillAmount, "alice native output mismatch");
        assertEq(hook.getBalanceOut(order, false), remainingOutBefore - fillAmount, "remaining output mismatch");
        assertEq(
            hook.getBalanceIn(order, false),
            remainingInBefore - (fillAmount * remainingInBefore / remainingOutBefore),
            "remaining input mismatch"
        );
        assertEq(
            manager.balanceOf(filler, poolKey.currency1.toId()) - fillerClaimsBefore,
            fillAmount * remainingInBefore / remainingOutBefore,
            "filler claims mismatch"
        );
    }

    function test_nativeOutput_fill_exactMin50Percent() public {
        uint256 amountIn = 1e18;

        vm.prank(alice);
        hook.swap(poolKey, false, amountIn, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order = _order(alice, ORDER_TICK);
        uint256 remainingOut = hook.getBalanceOut(order, false);
        uint256 minFill = (remainingOut + 1) / 2;

        vm.prank(filler);
        hook.fill{value: minFill}(order, false, minFill);

        assertEq(hook.getBalanceOut(order, false), remainingOut - minFill, "exact min fill should succeed");
    }

    function test_nativeOutput_cancelAfterPartialFill() public {
        vm.txGasPrice(0);
        uint256 amountIn = 1e18;

        vm.prank(alice);
        hook.swap(poolKey, false, amountIn, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order = _order(alice, ORDER_TICK);
        uint256 remainingOutBefore = hook.getBalanceOut(order, false);
        uint256 fillAmount = remainingOutBefore / 2;

        vm.prank(filler);
        hook.fill{value: fillAmount}(order, false, fillAmount);

        uint256 remainingIn = hook.getBalanceIn(order, false);
        uint256 aliceTokenBefore = token1.balanceOf(alice);

        vm.prank(alice);
        hook.cancelOrder(order, false);

        assertEq(token1.balanceOf(alice) - aliceTokenBefore, remainingIn, "cancel should return remaining token1 input");
        assertEq(hook.getBalanceIn(order, false), 0, "input should be cleared");
        assertEq(hook.getBalanceOut(order, false), 0, "output should be cleared");
    }

    function test_nativeInput_cancel_returns_eth() public {
        vm.txGasPrice(0);
        uint256 amountIn = 1 ether;

        vm.prank(alice);
        hook.swap{value: amountIn}(poolKey, true, amountIn, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order = _order(alice, ORDER_TICK);
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        hook.cancelOrder(order, true);

        assertEq(alice.balance, balanceBefore + _netInput(amountIn), "alice did not receive native refund");
        assertEq(hook.getBalanceIn(order, true), 0, "input should be cleared");
        assertEq(hook.getBalanceOut(order, true), 0, "output should be cleared");
    }

    function test_nativeInput_wrongMsgValue_reverts() public {
        uint256 amountIn = 1 ether;

        vm.prank(alice);
        vm.expectRevert(AsyncRouter.INVALID_NATIVE_VALUE.selector);
        hook.swap{value: amountIn - 1}(poolKey, true, amountIn, ORDER_TICK, 0, 0);
    }

    function test_erc20Input_withMsgValue_reverts() public {
        uint256 amountIn = 1e18;

        vm.prank(alice);
        vm.expectRevert(AsyncRouter.INVALID_NATIVE_VALUE.selector);
        hook.swap{value: 1}(poolKey, false, amountIn, ORDER_TICK, 0, 0);
    }

    function test_nativeOutput_wrongMsgValue_reverts() public {
        uint256 amountIn = 1e18;

        vm.prank(alice);
        hook.swap(poolKey, false, amountIn, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order = _order(alice, ORDER_TICK);
        uint256 expectedOut = hook.getBalanceOut(order, false);

        vm.prank(filler);
        vm.expectRevert(AsyncSwap.INVALID_NATIVE_OUTPUT_VALUE.selector);
        hook.fill{value: expectedOut - 1}(order, false, expectedOut);
    }

    function test_erc20Output_withMsgValue_reverts() public {
        uint256 amountIn = 1 ether;

        vm.prank(alice);
        hook.swap{value: amountIn}(poolKey, true, amountIn, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order = _order(alice, ORDER_TICK);
        uint256 expectedOut = hook.getBalanceOut(order, true);

        vm.prank(filler);
        vm.expectRevert(AsyncSwap.INVALID_NATIVE_OUTPUT_VALUE.selector);
        hook.fill{value: 1}(order, true, expectedOut);
    }

    function test_swap_paused_reverts_but_cancel_still_works() public {
        uint256 amountIn = 1 ether;

        hook.pause();

        vm.prank(alice);
        vm.expectRevert(IntentAuth.PAUSED.selector);
        hook.swap{value: amountIn}(poolKey, true, amountIn, ORDER_TICK, 0, 0);

        hook.unpause();

        vm.prank(alice);
        hook.swap{value: amountIn}(poolKey, true, amountIn, ORDER_TICK, 0, 0);

        AsyncSwap.Order memory order = _order(alice, ORDER_TICK);
        uint256 balBefore = alice.balance;
        uint256 expectedRefund = hook.getBalanceIn(order, true);

        hook.pause();

        vm.prank(alice);
        hook.cancelOrder(order, true);

        assertEq(alice.balance, balBefore + expectedRefund, "cancel should still work while paused");
    }
}
