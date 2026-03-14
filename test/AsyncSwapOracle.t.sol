// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {IntentAuth} from "../src/IntentAuth.sol";
import {IAsyncSwapOracle} from "../src/interfaces/IAsyncSwapOracle.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract AsyncSwapOracleTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AsyncSwap hook;
    PoolKey poolKey;
    PoolId poolId;
    MockAsyncSwapOracle oracle;
    address filler = makeAddr("filler");
    address treasury = makeAddr("treasury");

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(HOOK_FLAGS);
        deployCodeTo("AsyncSwap.sol:AsyncSwap", abi.encode(address(manager), address(this)), hookAddr);
        hook = AsyncSwap(hookAddr);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 240,
            hooks: IHooks(hookAddr)
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(filler, 100e18);
        address routerAddr = address(hook.router());
        MockERC20(Currency.unwrap(currency0)).approve(routerAddr, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(routerAddr, type(uint256).max);
        vm.prank(filler);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        oracle = new MockAsyncSwapOracle();
    }

    function test_setOracleConfig_nonOwner_reverts() public {
        vm.prank(makeAddr("mallory"));
        vm.expectRevert(bytes("NOT OWNER"));
        hook.setOracleConfig(poolId, oracle, 300, 100, 5000, 2500, 2500);
    }

    function test_setOracleConfig_invalidSplit_reverts() public {
        vm.expectRevert(bytes("INVALID_SPLIT"));
        hook.setOracleConfig(poolId, oracle, 300, 100, 5000, 2500, 2000);
    }

    function test_previewSurplusCapture_inactive_withoutOracle() public {
        hook.swap(poolKey, true, 1e18, -500, 0, 0);
        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: poolId, swapper: address(this), tick: -500});
        uint256 fillAmount = hook.getBalanceOut(order, true);

        AsyncSwap.SurplusPreview memory preview = hook.previewSurplusCapture(order, true, fillAmount);
        assertFalse(preview.active);
        assertEq(preview.surplus, 0);
    }

    function test_previewSurplusCapture_active_on_badQuote() public {
        oracle.setQuote(0, block.timestamp);
        hook.setOracleConfig(poolId, oracle, 300, 100, 5000, 2500, 2500);

        hook.swap(poolKey, true, 1e18, -500, 0, 0);
        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: poolId, swapper: address(this), tick: -500});
        uint256 fillAmount = hook.getBalanceOut(order, true);

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
        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: poolId, swapper: address(this), tick: -500});
        uint256 fillAmount = hook.getBalanceOut(order, true);

        AsyncSwap.SurplusPreview memory preview = hook.previewSurplusCapture(order, true, fillAmount);
        assertFalse(preview.active);
    }

    function test_oracleCapture_accruesSurplus_and_user_can_reclaim_share() public {
        oracle.setQuote(0, block.timestamp);
        hook.setOracleConfig(poolId, oracle, 300, 100, 5000, 2500, 2500);
        hook.setTreasury(treasury);

        hook.swap(poolKey, true, 1e18, -500, 0, 0);
        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: poolId, swapper: address(this), tick: -500});
        uint256 fillAmount = hook.getBalanceOut(order, true);

        uint256 fillerClaimsBefore = manager.balanceOf(filler, currency0.toId());
        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        uint256 fillerClaimsAfter = manager.balanceOf(filler, currency0.toId()) - fillerClaimsBefore;
        assertGt(hook.accruedSurplus(currency0), 0, "protocol should capture surplus");
        assertGt(hook.getBalanceIn(order, true), 0, "user should retain surplus share in order balance");
        assertLt(fillerClaimsAfter, 988_000_000_000_000_000, "filler should not keep all surplus");

        uint256 userBalBefore = currency0.balanceOf(address(this));
        hook.cancelOrder(order, true);
        assertGt(currency0.balanceOf(address(this)) - userBalBefore, 0, "user should reclaim surplus share on cancel");

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

    function test_oracleCapture_onFillMode_accruesSurplus_and_preserves_user_share() public {
        oracle.setQuote(0, block.timestamp);
        hook.setOracleConfig(poolId, oracle, 300, 100, 5000, 2500, 2500);
        hook.setFeeRefundToggle(true);
        hook.setTreasury(treasury);

        hook.swap(poolKey, true, 1e18, -500, 0, 0);
        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: poolId, swapper: address(this), tick: -500});
        uint256 fillAmount = hook.getBalanceOut(order, true);

        uint256 fillerClaimsBefore = manager.balanceOf(filler, currency0.toId());
        vm.prank(filler);
        hook.fill(order, true, fillAmount);

        uint256 fillerClaimsAfter = manager.balanceOf(filler, currency0.toId()) - fillerClaimsBefore;
        assertGt(hook.accruedSurplus(currency0), 0, "protocol should capture surplus in on-fill mode");
        assertGt(hook.getBalanceIn(order, true), 0, "user should retain share in order balance");
        assertLt(fillerClaimsAfter, 988_000_000_000_000_000, "filler should not keep all upside");

        uint256 userBalBefore = currency0.balanceOf(address(this));
        hook.cancelOrder(order, true);
        assertGt(currency0.balanceOf(address(this)) - userBalBefore, 0, "user should reclaim residual share on cancel");

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
