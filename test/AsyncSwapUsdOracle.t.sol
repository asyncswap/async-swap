// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {IntentAuth} from "../src/IntentAuth.sol";
import {ITokenPriceOracle} from "../src/interfaces/ITokenPriceOracle.sol";
import {IAsyncSwapOracle} from "../src/interfaces/IAsyncSwapOracle.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Order, OrderLibrary} from "src/types/Order.sol";

contract AsyncSwapUsdOracleTest is SetupHook {
    using PoolIdLibrary for PoolKey;
    using OrderLibrary for Order;

    MockTokenPriceOracle priceOracle;
    address filler = makeAddr("filler");
    address treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();

        priceOracle = new MockTokenPriceOracle();
        hook.setTokenPriceOracle(priceOracle);
        hook.setTreasury(treasury);

        // Configure oracle surplus policy for this pool
        hook.setOracleConfig(poolId, IAsyncSwapOracle(address(0)), 300, 100, 5000, 2500, 2500);

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(filler, 100e18);
        vm.prank(filler);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function test_usdOracle_fairFill_noCapture() public {
        // Both tokens priced at $1 — fair at tick 0
        priceOracle.setPrice(Currency.unwrap(currency0), 1e18, block.timestamp);
        priceOracle.setPrice(Currency.unwrap(currency1), 1e18, block.timestamp);

        _swap(true, 1e18, 0, 0);
        Order memory order = _makeOrder(address(this), 0);
        uint256 fillAmount = hook.getBalanceOut(order.toId(), true);

        AsyncSwap.SurplusPreview memory preview = hook.previewUsdSurplusCapture(order, true, fillAmount);
        assertFalse(preview.active, "should not capture surplus on fair fill");
    }

    function test_usdOracle_userDisadvantaged_capturesSurplus() public {
        // token0 worth $2, token1 worth $1
        // At tick 0 (price 1:1), user is overpaying
        priceOracle.setPrice(Currency.unwrap(currency0), 2e18, block.timestamp);
        priceOracle.setPrice(Currency.unwrap(currency1), 1e18, block.timestamp);

        _swap(true, 1e18, 0, 0);
        Order memory order = _makeOrder(address(this), 0);
        uint256 fillAmount = hook.getBalanceOut(order.toId(), true);

        AsyncSwap.SurplusPreview memory preview = hook.previewUsdSurplusCapture(order, true, fillAmount);
        assertTrue(preview.active, "should capture surplus when user overpays");
        assertTrue(preview.disadvantaged == AsyncSwap.Disadvantaged.User);
        assertGt(preview.surplus, 0);
        assertGt(preview.userShare, 0);
        assertGt(preview.protocolShare, 0);
    }

    function test_usdOracle_fillerDisadvantaged_detected() public {
        // token0 worth $0.5, token1 worth $1
        // At tick 0 (price 1:1), filler is overpaying
        priceOracle.setPrice(Currency.unwrap(currency0), 0.5e18, block.timestamp);
        priceOracle.setPrice(Currency.unwrap(currency1), 1e18, block.timestamp);

        _swap(true, 1e18, 0, 0);
        Order memory order = _makeOrder(address(this), 0);
        uint256 fillAmount = hook.getBalanceOut(order.toId(), true);

        AsyncSwap.SurplusPreview memory preview = hook.previewUsdSurplusCapture(order, true, fillAmount);
        assertFalse(preview.active, "filler protection is informational only");
        assertTrue(preview.disadvantaged == AsyncSwap.Disadvantaged.Filler);
        assertGt(preview.surplus, 0);
    }

    function test_usdOracle_missingPrice_fallsBackToSqrtPrice() public {
        // Only set price for one token — should fall back to v1.0 path
        priceOracle.setPrice(Currency.unwrap(currency0), 1e18, block.timestamp);
        // currency1 has no price → getPrice returns 0

        _swap(true, 1e18, 0, 0);
        Order memory order = _makeOrder(address(this), 0);
        uint256 fillAmount = hook.getBalanceOut(order.toId(), true);

        // Should not revert — graceful fallback
        AsyncSwap.SurplusPreview memory preview = hook.previewUsdSurplusCapture(order, true, fillAmount);
        // With no sqrtPriceX96 oracle configured either, should return inactive
        assertFalse(preview.active);
    }

    function test_usdOracle_stalePrice_returnsInactive() public {
        vm.warp(2000);
        priceOracle.setPrice(Currency.unwrap(currency0), 1e18, block.timestamp - 1000);
        priceOracle.setPrice(Currency.unwrap(currency1), 1e18, block.timestamp - 1000);

        _swap(true, 1e18, 0, 0);
        Order memory order = _makeOrder(address(this), 0);
        uint256 fillAmount = hook.getBalanceOut(order.toId(), true);

        AsyncSwap.SurplusPreview memory preview = hook.previewUsdSurplusCapture(order, true, fillAmount);
        assertFalse(preview.active, "stale prices should skip capture");
    }

    function test_usdOracle_enforcesUserRebateOnFill() public {
        priceOracle.setPrice(Currency.unwrap(currency0), 2e18, block.timestamp);
        priceOracle.setPrice(Currency.unwrap(currency1), 1e18, block.timestamp);

        _swap(true, 1e18, 0, 0);
        Order memory order = _makeOrder(address(this), 0);
        uint256 fillAmount = hook.getBalanceOut(order.toId(), true);

        uint256 userClaimsBefore = manager.balanceOf(address(this), currency0.toId());
        vm.prank(filler);
        hook.fill(order, true, fillAmount);
        uint256 userClaimsAfter = manager.balanceOf(address(this), currency0.toId());

        assertGt(userClaimsAfter - userClaimsBefore, 0, "user should receive immediate rebate");
        assertGt(hook.accruedSurplus(currency0), 0, "protocol should accrue surplus");
    }
}

contract MockTokenPriceOracle is ITokenPriceOracle {
    mapping(address => uint256) internal prices;
    mapping(address => uint256) internal timestamps;

    function setPrice(address token, uint256 priceX18, uint256 updatedAt) external {
        prices[token] = priceX18;
        timestamps[token] = updatedAt;
    }

    function getPrice(address token) external view returns (uint256 priceX18, uint256 updatedAt) {
        return (prices[token], timestamps[token]);
    }
}
