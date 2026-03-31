// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {IntentAuth} from "../src/IntentAuth.sol";
import {IAsyncSwapOracle} from "../src/interfaces/IAsyncSwapOracle.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Order, OrderLibrary} from "src/types/Order.sol";

contract AsyncSwapOracleTest is SetupHook {
    using PoolIdLibrary for PoolKey;
    using OrderLibrary for Order;

    MockAsyncSwapOracle oracle;
    address filler = makeAddr("filler");
    address treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(filler, 100e18);
        vm.prank(filler);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        oracle = new MockAsyncSwapOracle();
    }

    function test_setOracleConfig_nonOwner_reverts() public {
        vm.prank(makeAddr("mallory"));
        vm.expectRevert(IntentAuth.NOT_PROTOCOL_OWNER.selector);
        hook.setOracleConfig(poolId, oracle, 300, 100, 5000, 2500, 2500);
    }

    function test_setOracleConfig_invalidSplit_reverts() public {
        vm.expectRevert(bytes("INVALID_SPLIT"));
        hook.setOracleConfig(poolId, oracle, 300, 100, 5000, 2500, 2000);
    }

    function test_previewSurplusCapture_inactive_withoutOracle() public {
        hook.swap(poolKey, true, 1e18, -500, 0, 0);
        Order memory order = Order({poolId: poolId, swapper: address(this), tick: -500});
        uint256 fillAmount = hook.getBalanceOut(order.toId(), true);

        AsyncSwap.SurplusPreview memory preview = hook.previewSurplusCapture(order, true, fillAmount);
        assertFalse(preview.active);
        assertEq(preview.surplus, 0);
    }

    function test_previewSurplusCapture_active_on_badQuote() public {
        oracle.setQuote(0, block.timestamp);
        hook.setOracleConfig(poolId, oracle, 300, 100, 5000, 2500, 2500);

        hook.swap(poolKey, true, 1e18, -500, 0, 0);
        Order memory order = Order({poolId: poolId, swapper: address(this), tick: -500});
        uint256 fillAmount = hook.getBalanceOut(order.toId(), true);

        AsyncSwap.SurplusPreview memory preview = hook.previewSurplusCapture(order, true, fillAmount);
        assertTrue(preview.active);
        assertGt(preview.surplus, 0);
        assertEq(preview.userShare + preview.protocolShare + (preview.fillerShare - preview.fairShare), preview.surplus);
    }

    function test_previewSurplusCapture_staleOracle_returnsInactive() public {
        vm.warp(2000);
        oracle.setQuote(0, block.timestamp - 1000);
        hook.setOracleConfig(poolId, oracle, 60, 100, 5000, 2500, 2500);

        hook.swap(poolKey, true, 1e18, -500, 0, 0);
        Order memory order = Order({poolId: poolId, swapper: address(this), tick: -500});
        uint256 fillAmount = hook.getBalanceOut(order.toId(), true);

        AsyncSwap.SurplusPreview memory preview = hook.previewSurplusCapture(order, true, fillAmount);
        assertFalse(preview.active);
    }

    function test_oracleCapture_accruesSurplus_and_user_receives_immediate_rebate() public {
        oracle.setQuote(0, block.timestamp);
        hook.setOracleConfig(poolId, oracle, 300, 100, 5000, 2500, 2500);
        hook.setTreasury(treasury);

        hook.swap(poolKey, true, 1e18, -500, 0, 0);
        Order memory order = Order({poolId: poolId, swapper: address(this), tick: -500});
        uint256 fillAmount = hook.getBalanceOut(order.toId(), true);

        uint256 userClaimsBefore = manager.balanceOf(address(this), currency0.toId());
        uint256 fillerClaimsBefore = manager.balanceOf(filler, currency0.toId());
        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        uint256 fillerClaimsAfter = manager.balanceOf(filler, currency0.toId()) - fillerClaimsBefore;
        uint256 userClaimsAfter = manager.balanceOf(address(this), currency0.toId()) - userClaimsBefore;
        assertGt(hook.accruedSurplus(currency0), 0, "protocol should capture surplus");
        assertGt(userClaimsAfter, 0, "user should receive immediate rebate");
        assertLt(fillerClaimsAfter, 988_000_000_000_000_000, "filler should not keep all surplus");

        uint256 treasuryBefore = currency0.balanceOf(treasury);
        hook.claimSurplus(currency0);
        assertGt(currency0.balanceOf(treasury) - treasuryBefore, 0, "treasury should receive protocol surplus");
        assertEq(hook.accruedSurplus(currency0), 0, "surplus should be cleared after claim");
    }

    function test_claimSurplus_noSurplus_reverts() public {
        hook.setTreasury(treasury);
        vm.expectRevert(IntentAuth.NO_SURPLUS_ACCRUED.selector);
        hook.claimSurplus(currency0);
    }

    function test_oracleCapture_onFillMode_user_receives_immediate_rebate() public {
        oracle.setQuote(0, block.timestamp);
        hook.setOracleConfig(poolId, oracle, 300, 100, 5000, 2500, 2500);
        hook.setFeeRefundToggle(true);
        hook.setTreasury(treasury);

        hook.swap(poolKey, true, 1e18, -500, 0, 0);
        Order memory order = Order({poolId: poolId, swapper: address(this), tick: -500});
        uint256 fillAmount = hook.getBalanceOut(order.toId(), true);

        uint256 userClaimsBefore = manager.balanceOf(address(this), currency0.toId());
        uint256 fillerClaimsBefore = manager.balanceOf(filler, currency0.toId());
        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        uint256 fillerClaimsAfter = manager.balanceOf(filler, currency0.toId()) - fillerClaimsBefore;
        uint256 userClaimsAfter = manager.balanceOf(address(this), currency0.toId()) - userClaimsBefore;
        assertGt(hook.accruedSurplus(currency0), 0, "protocol should capture surplus in on-fill mode");
        assertGt(userClaimsAfter, 0, "user should receive immediate rebate in on-fill mode");
        assertLt(fillerClaimsAfter, 988_000_000_000_000_000, "filler should not keep all upside");

        uint256 treasuryBefore = currency0.balanceOf(treasury);
        hook.claimSurplus(currency0);
        assertGt(currency0.balanceOf(treasury) - treasuryBefore, 0, "treasury should receive protocol surplus");
    }
}

contract MockAsyncSwapOracle is IAsyncSwapOracle {
    uint160 internal quoteSqrtPriceX96;
    uint256 internal updatedAt;

    function setQuote(int24 _tick, uint256 _updatedAt) external {
        quoteSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_tick);
        updatedAt = _updatedAt;
    }

    function getQuoteSqrtPriceX96(PoolId) external view returns (uint160 sqrtPriceX96, uint256 timestamp) {
        return (quoteSqrtPriceX96, updatedAt);
    }
}
