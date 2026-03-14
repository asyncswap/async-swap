// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {AsyncSwap} from "./AsyncSwap.sol";

/// @title AsyncRouter
/// @notice Thin router that calls PM.swap() so beforeSwap fires on the hook.
///         Only callable by the hook itself — captures msg.sender (the user) from the hook.
contract AsyncRouter is IUnlockCallback {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable POOL_MANAGER;
    address public immutable HOOK;

    struct SwapData {
        address user;
        PoolKey key;
        int24 tick;
        uint256 amountIn;
        bool zeroForOne;
        uint256 minAmountOut;
    }

    error ONLY_HOOK();
    error ONLY_POOL_MANAGER();

    constructor(IPoolManager _pm, address _hook) {
        POOL_MANAGER = _pm;
        HOOK = _hook;
    }

    /// @notice Called by the hook to execute a swap through PM.swap()
    function executeSwap(SwapData calldata data) external {
        if (msg.sender != HOOK) revert ONLY_HOOK();
        POOL_MANAGER.unlock(abi.encode(data));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert ONLY_POOL_MANAGER();

        SwapData memory cb = abi.decode(data, (SwapData));

        // Build the Order struct and hookData that beforeSwap expects
        AsyncSwap.Order memory order = AsyncSwap.Order({
            poolId: cb.key.toId(),
            swapper: cb.user,
            tick: cb.tick
        });

        // Call PM.swap() — this triggers hook.beforeSwap() since msg.sender is this router, not the hook
        POOL_MANAGER.swap(
            cb.key,
            SwapParams({
                zeroForOne: cb.zeroForOne,
                amountSpecified: -int256(cb.amountIn),
                sqrtPriceLimitX96: cb.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(order, cb.minAmountOut)
        );

        // Settle: user pays input tokens to PoolManager
        Currency inputCurrency = cb.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        inputCurrency.settle(POOL_MANAGER, cb.user, cb.amountIn, false);

        return "";
    }
}
