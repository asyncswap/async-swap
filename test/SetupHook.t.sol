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

/// @title SetupHook
/// @notice Shared test base for AsyncSwap tests.
///         Handles deployment, configuration, pool initialization, and unpause.
///         Individual test contracts inherit from this and override setUp() if needed.
contract SetupHook is Test, Deployers {
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

    function setUp() public virtual {
        deployManager();
        deployHook();
        deployTokens();
        initializePool();
        unpauseProtocol();
    }

    function deployManager() public {
        deployFreshManagerAndRouters();
    }

    function deployHook() public {
        address hookAddr = address(HOOK_FLAGS);
        deployCodeTo("AsyncSwap.sol:AsyncSwap", abi.encode(address(manager), address(this)), hookAddr);
        hook = AsyncSwap(hookAddr);
        asyncRouter = hook.router();
    }

    function deployTokens() public {
        deployMintAndApprove2Currencies();

        address routerAddr = address(asyncRouter);
        MockERC20(Currency.unwrap(currency0)).approve(routerAddr, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(routerAddr, type(uint256).max);
    }

    function initializePool() public {
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function unpauseProtocol() public {
        hook.unpause();
    }

    function _netInput(uint256 amount) internal view returns (uint256) {
        uint256 fee = FullMath.mulDivRoundingUp(amount, hook.poolFee(poolId), 1_000_000);
        return amount - fee;
    }

    function _makeOrder(address swapper, int24 tick) internal view returns (AsyncSwap.Order memory) {
        return AsyncSwap.Order({poolId: poolId, swapper: swapper, tick: tick});
    }

    function _swap(bool zeroForOne, uint256 amountIn, int24 tick, uint256 minAmountOut) internal {
        hook.swap(poolKey, zeroForOne, amountIn, tick, minAmountOut, 0);
    }
}
