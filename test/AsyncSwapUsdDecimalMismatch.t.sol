// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {AsyncRouter} from "../src/AsyncRouter.sol";
import {IntentAuth} from "../src/IntentAuth.sol";
import {ITokenPriceOracle} from "../src/interfaces/ITokenPriceOracle.sol";
import {IAsyncSwapOracle} from "../src/interfaces/IAsyncSwapOracle.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/// @title AsyncSwapUsdDecimalMismatchTest
/// @notice Tests that the USD surplus path correctly scales fairClaimShare
///         for pools with mixed-decimal tokens (e.g., 6-decimal USDC + 18-decimal WETH).
///
///         At tick 0 the raw exchange rate is 1:1, so 1e6 raw of token6 = 1e6 raw of token18.
///         The USD oracle must reflect this: if token6=$1 then 1e6 raw token6 = $1,
///         and 1e6 raw token18 = token18_price * 1e6/1e18 = token18_price * 1e-12 in USD.
///         For tick 0 to be fair: $1 = token18_price * 1e-12 => token18_price = $1e12.
///
///         The key invariant: fairClaimShare must be in INPUT token decimals and close
///         to claimShare when oracle prices match the tick exchange rate.
contract AsyncSwapUsdDecimalMismatchTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AsyncSwap hook;
    AsyncRouter asyncRouter;
    PoolKey poolKey;
    PoolId poolId;
    MockTokenPriceOracle6 priceOracle;

    MockERC20 token6; // 6 decimals (like USDC)
    MockERC20 token18; // 18 decimals (like WETH)

    address filler = makeAddr("filler");
    address treasury = makeAddr("treasury");

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint24 constant HOOK_FEE = 1_2000;
    int24 constant TICK_SPACING = 240;
    int24 constant ORDER_TICK = 0;

    function setUp() public {
        deployFreshManagerAndRouters();

        address hookAddr = address(HOOK_FLAGS);
        deployCodeTo("AsyncSwap.sol:AsyncSwap", abi.encode(address(manager), address(this), HOOK_FEE), hookAddr);
        hook = AsyncSwap(hookAddr);
        asyncRouter = hook.router();

        token6 = new MockERC20("USDC", "USDC", 6);
        token18 = new MockERC20("WETH", "WETH", 18);

        Currency cur0;
        Currency cur1;
        if (address(token6) < address(token18)) {
            cur0 = Currency.wrap(address(token6));
            cur1 = Currency.wrap(address(token18));
        } else {
            cur0 = Currency.wrap(address(token18));
            cur1 = Currency.wrap(address(token6));
        }

        poolKey = PoolKey({
            currency0: cur0,
            currency1: cur1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        hook.unpause();

        priceOracle = new MockTokenPriceOracle6();
        hook.setTokenPriceOracle(priceOracle);
        hook.setTreasury(treasury);
        // maxDeviationBps=0 means always capture if surplus exists
        hook.setOracleConfig(poolId, IAsyncSwapOracle(address(0)), 300, 0, 5000, 2500, 2500);

        token6.mint(address(this), 1_000_000e6);
        token18.mint(address(this), 1_000e18);
        token6.mint(filler, 1_000_000e6);
        token18.mint(filler, 1_000e18);

        token6.approve(address(asyncRouter), type(uint256).max);
        token18.approve(address(asyncRouter), type(uint256).max);
        vm.startPrank(filler);
        token6.approve(address(hook), type(uint256).max);
        token18.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _isToken6Currency0() internal view returns (bool) {
        return Currency.unwrap(poolKey.currency0) == address(token6);
    }

    function _makeOrder(address swapper, int24 tick) internal view returns (AsyncSwap.Order memory) {
        return AsyncSwap.Order({poolId: poolId, swapper: swapper, tick: tick});
    }

    /// @notice When oracle prices match the tick 0 raw exchange rate,
    ///         fairClaimShare should equal claimShare (no surplus).
    ///         At tick 0: 1 raw token6 = 1 raw token18.
    ///         If token6 = $1, then 1e6 raw = $1, and 1e6 raw token18 = $price18 * 1e-12.
    ///         For fairness: price18 = 1e12.
    function test_usdOracle_mixedDecimals_fairPrices_noSurplus() public {
        // Set prices consistent with tick 0 (1:1 raw exchange)
        // token6 at $1/token => $1e-6 per raw unit
        // token18 at $1e12/token => $1e-6 per raw unit (same per-raw-unit value)
        priceOracle.setPrice(address(token6), 1e18, block.timestamp);
        priceOracle.setPrice(address(token18), 1e30, block.timestamp); // $1e12 in D18

        bool zeroForOne = _isToken6Currency0();
        hook.swap(poolKey, zeroForOne, 1000e6, ORDER_TICK, 0, 0);
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        uint256 fillAmount = hook.getBalanceOut(order, zeroForOne);

        AsyncSwap.SurplusPreview memory preview = hook.previewUsdSurplusCapture(order, zeroForOne, fillAmount);

        // With matching prices, there should be no surplus (or within tolerance)
        assertFalse(preview.active, "should not capture surplus when prices match tick");
    }

    /// @notice The core decimal test: fairClaimShare must be in input-token decimals.
    ///         We verify by checking that fairShare and claimShare are within 2x of each other
    ///         when prices approximately match the tick. Before the fix, there would be a
    ///         1e12x discrepancy for 6/18-decimal pairs.
    function test_usdOracle_mixedDecimals_fairClaimShareScale() public {
        priceOracle.setPrice(address(token6), 1e18, block.timestamp);
        priceOracle.setPrice(address(token18), 1e30, block.timestamp);

        bool zeroForOne = _isToken6Currency0();
        hook.swap(poolKey, zeroForOne, 1000e6, ORDER_TICK, 0, 0);
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        uint256 fillAmount = hook.getBalanceOut(order, zeroForOne);

        AsyncSwap.SurplusPreview memory preview = hook.previewUsdSurplusCapture(order, zeroForOne, fillAmount);

        // Both values should be in the same decimal scale (input token decimals)
        // With matching prices, they should be very close
        if (preview.fairShare > 0 && preview.claimShare > 0) {
            uint256 ratio = preview.claimShare > preview.fairShare
                ? preview.claimShare / preview.fairShare
                : preview.fairShare / preview.claimShare;
            assertLe(ratio, 2, "fairShare and claimShare should be within 2x when prices match tick");
        }
    }

    /// @notice Test the reverse direction: swap 18-decimal → 6-decimal.
    function test_usdOracle_mixedDecimals_reverse_fairClaimShareScale() public {
        priceOracle.setPrice(address(token6), 1e18, block.timestamp);
        priceOracle.setPrice(address(token18), 1e30, block.timestamp);

        bool zeroForOne = !_isToken6Currency0();
        hook.swap(poolKey, zeroForOne, 1e18, ORDER_TICK, 0, 0);
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        uint256 fillAmount = hook.getBalanceOut(order, zeroForOne);

        AsyncSwap.SurplusPreview memory preview = hook.previewUsdSurplusCapture(order, zeroForOne, fillAmount);

        if (preview.fairShare > 0 && preview.claimShare > 0) {
            uint256 ratio = preview.claimShare > preview.fairShare
                ? preview.claimShare / preview.fairShare
                : preview.fairShare / preview.claimShare;
            assertLe(ratio, 2, "reverse direction: fairShare and claimShare should be within 2x");
        }
    }

    /// @notice When oracle prices diverge from tick (user overpaying), surplus must be detected
    ///         even with mixed decimals. Set token18=$0.5e12 (half the fair tick-0 price of $1e12).
    ///         User is selling token6 for token18 at tick 0, but oracle says token18 is worth less
    ///         per raw unit — user's input buys less USD value of output than fair.
    function test_usdOracle_mixedDecimals_userDisadvantaged() public {
        // token18 is half the fair price — user overpays (gives $1 of input, gets $0.50 of output)
        priceOracle.setPrice(address(token6), 1e18, block.timestamp);
        priceOracle.setPrice(address(token18), 5e29, block.timestamp); // $0.5e12 per token18

        bool zeroForOne = _isToken6Currency0();
        hook.swap(poolKey, zeroForOne, 1000e6, ORDER_TICK, 0, 0);
        AsyncSwap.Order memory order = _makeOrder(address(this), ORDER_TICK);
        uint256 fillAmount = hook.getBalanceOut(order, zeroForOne);

        AsyncSwap.SurplusPreview memory preview = hook.previewUsdSurplusCapture(order, zeroForOne, fillAmount);

        assertTrue(preview.disadvantaged == AsyncSwap.Disadvantaged.User, "user should be disadvantaged");
        assertGt(preview.surplus, 0, "surplus should be positive");
    }

    /// @notice Same-decimal tokens (18/18) should still work correctly (regression).
    function test_usdOracle_sameDecimals_stillWorks() public {
        // Deploy two 18-decimal tokens and set up a second pool
        MockERC20 tokenA = new MockERC20("TKA", "TKA", 18);
        MockERC20 tokenB = new MockERC20("TKB", "TKB", 18);

        Currency curA = Currency.wrap(address(tokenA));
        Currency curB = Currency.wrap(address(tokenB));
        if (address(tokenA) > address(tokenB)) {
            (curA, curB) = (curB, curA);
        }

        PoolKey memory key2 = PoolKey({
            currency0: curA,
            currency1: curB,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId pid2 = key2.toId();
        manager.initialize(key2, SQRT_PRICE_1_1);
        hook.setOracleConfig(pid2, IAsyncSwapOracle(address(0)), 300, 0, 5000, 2500, 2500);

        tokenA.mint(address(this), 100e18);
        tokenB.mint(address(this), 100e18);
        tokenA.approve(address(asyncRouter), type(uint256).max);
        tokenB.approve(address(asyncRouter), type(uint256).max);

        priceOracle.setPrice(address(tokenA), 1e18, block.timestamp);
        priceOracle.setPrice(address(tokenB), 1e18, block.timestamp);

        hook.swap(key2, true, 1e18, ORDER_TICK, 0, 0);
        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: pid2, swapper: address(this), tick: ORDER_TICK});
        uint256 fillAmount = hook.getBalanceOut(order, true);

        AsyncSwap.SurplusPreview memory preview = hook.previewUsdSurplusCapture(order, true, fillAmount);
        assertFalse(preview.active, "same-decimal fair fill should not capture surplus");
    }
}

contract MockTokenPriceOracle6 is ITokenPriceOracle {
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
