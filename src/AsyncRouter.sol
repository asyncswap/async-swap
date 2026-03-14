// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {AsyncSwap} from "./AsyncSwap.sol";

/// @title AsyncRouter
/// @notice Thin router that calls PM.swap() so beforeSwap fires on the hook.
///         Only callable by the hook itself — captures msg.sender (the user) from the hook.
contract AsyncRouter is IUnlockCallback {
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
    error SWAP_NOT_NOOPED();
    error UNSUPPORTED_INPUT_TOKEN();

    constructor(IPoolManager _pm, address _hook) {
        POOL_MANAGER = _pm;
        HOOK = _hook;
    }

    /// @notice Called by the hook to execute a swap through PM.swap()
    function executeSwap(SwapData calldata data) external {
        if (msg.sender != HOOK) revert ONLY_HOOK();
        POOL_MANAGER.unlock(abi.encode(data));
    }

    function _settleExactInput(Currency inputCurrency, address payer, uint256 amount) internal {
        if (inputCurrency.isAddressZero()) revert UNSUPPORTED_INPUT_TOKEN();

        POOL_MANAGER.sync(inputCurrency);
        IERC20Minimal(Currency.unwrap(inputCurrency)).transferFrom(payer, address(POOL_MANAGER), amount);
        uint256 paid = POOL_MANAGER.settle();
        if (paid != amount) revert UNSUPPORTED_INPUT_TOKEN();
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
        BalanceDelta delta = POOL_MANAGER.swap(
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

        // Validate that beforeSwap fully absorbed the swap — AMM should be no-op'd.
        // The swapDelta is the router's obligation: (-amountIn) on specified, 0 on unspecified.
        int128 specifiedDelta = cb.zeroForOne ? delta.amount0() : delta.amount1();
        int128 unspecifiedDelta = cb.zeroForOne ? delta.amount1() : delta.amount0();
        if (specifiedDelta != -int128(int256(cb.amountIn)) || unspecifiedDelta != 0) revert SWAP_NOT_NOOPED();

        // Settle: user pays exactly what the delta requires
        Currency inputCurrency = cb.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        _settleExactInput(inputCurrency, cb.user, cb.amountIn);

        return "";
    }
}
