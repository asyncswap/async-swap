// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Order, OrderLibrary} from "./types/Order.sol";

/// @title AsyncRouter
/// @notice Thin router that calls PM.swap() so beforeSwap fires on the hook.
/// Only callable by the hook itself — captures msg.sender (the user) from the hook.
contract AsyncRouter is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using OrderLibrary for Order;

    IPoolManager public immutable POOL_MANAGER;
    address public immutable HOOK;

    struct SwapData {
        address user;
        PoolKey key;
        int24 tick;
        uint256 amountIn; // {tok} exact input amount
        bool zeroForOne;
        uint256 minAmountOut; // {tok} minimum output (slippage protection)
        uint256 value; // {tok} native ETH value (0 for ERC-20)
    }

    error ONLY_HOOK();
    error ONLY_POOL_MANAGER();
    error SWAP_NOT_NOOPED();
    error UNSUPPORTED_INPUT_TOKEN();
    error INPUT_TRANSFER_FAILED();
    error INVALID_NATIVE_VALUE();

    constructor(IPoolManager _pm, address _hook) {
        POOL_MANAGER = _pm;
        HOOK = _hook;
    }

    /// @notice Called by the hook to execute a swap through PM.swap()
    function executeSwap(SwapData calldata data) external payable {
        if (msg.sender != HOOK) revert ONLY_HOOK();

        Currency inputCurrency = data.zeroForOne ? data.key.currency0 : data.key.currency1;
        if (inputCurrency.isAddressZero()) {
            if (msg.value != data.amountIn || data.value != data.amountIn) revert INVALID_NATIVE_VALUE();
        } else {
            if (msg.value != 0 || data.value != 0) revert INVALID_NATIVE_VALUE();
        }

        POOL_MANAGER.unlock(abi.encode(data));
    }

    /// @param amount {tok} Exact input amount to settle
    /// @param value {tok} Native ETH value (0 for ERC-20)
    function _settleExactInput(Currency inputCurrency, address payer, uint256 amount, uint256 value) internal {
        if (inputCurrency.isAddressZero()) {
            if (value != amount) revert INVALID_NATIVE_VALUE();
            uint256 paidNative = POOL_MANAGER.settle{value: amount}();
            if (paidNative != amount) revert UNSUPPORTED_INPUT_TOKEN();
            return;
        }

        if (value != 0) revert INVALID_NATIVE_VALUE();

        POOL_MANAGER.sync(inputCurrency);
        (bool callSuccess, bytes memory returndata) = Currency.unwrap(inputCurrency)
            .call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, payer, address(POOL_MANAGER), amount));
        if (!callSuccess || (returndata.length > 0 && !abi.decode(returndata, (bool)))) {
            revert INPUT_TRANSFER_FAILED();
        }
        uint256 paid = POOL_MANAGER.settle();
        if (paid != amount) revert UNSUPPORTED_INPUT_TOKEN();
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert ONLY_POOL_MANAGER();

        SwapData memory cb = abi.decode(data, (SwapData));

        // Build the Order struct and hookData that beforeSwap expects
        Order memory order = Order({poolId: cb.key.toId(), swapper: cb.user, tick: cb.tick});

        // Call PM.swap() — this triggers hook.beforeSwap() since msg.sender is this router, not the hook
        BalanceDelta delta = POOL_MANAGER.swap(
            cb.key,
            SwapParams({
                zeroForOne: cb.zeroForOne,
                amountSpecified: -int256(cb.amountIn),
                sqrtPriceLimitX96: cb.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1 // Q96{sqrt(tok1/tok0)}
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
        _settleExactInput(inputCurrency, cb.user, cb.amountIn, cb.value);

        return "";
    }

    receive() external payable {}
}
