// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

contract AsyncSwap layout at 1000 is IHooks {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    /// @notice The PoolManager contract address
    IPoolManager public immutable POOL_MANAGER;

    /// @notice The minimum fee charged by the protocol in bips 1.2%
    uint24 public minimumFee = 1_2000;

    /// @notice The Owner
    address public owner;
    /// @notice The Router
    address public router;

    /// Stores pools registered on this hook
    mapping(PoolId poolId => PoolKey key) public pools;
    /// Swap orders for input token0
    /// balancesIn initialized by swapper and mutated by filler
    mapping(bytes32 orderId => mapping(bool zeroForOne => uint256 amountGiven)) public balancesIn;
    /// Swap orders for output token1
    /// balancesOut initialized by swapper and mutated by filler
    mapping(bytes32 orderId => mapping(bool zeroForOne => uint256 amountTaken)) public balancesOut;

    /// @param swapper creator of order
    /// @param zeroForOne direction of order
    /// @param tick the tick market value to execute order
    /// @param amountIn amount of token given
    /// @param amountOut amount of token to be taken
    struct Order {
        PoolId poolId;
        address swapper;
        int24 tick;
        uint256 amountOut;
    }

    /// @notice A swap event
    event Swap(bytes32 orderId, Order order);

    /// @notice Error if caller is not poolmanager address
    error CALLER_NOT_POOL_MANAGER();

    /// @notice Error for method not implemented
    error HOOK_NOT_IN_USE();

    /// @notice Just become a filler instead
    error PROVIDE_LIQUIDITY_BY_SOLVING();

    /// @notice Initialize PoolManager storage variable
    constructor(IPoolManager _pm) {
        POOL_MANAGER = _pm;
        owner = msg.sender;
    }

    /// @notice Only PoolManager contract allowed as msg.sender
    modifier onlyPoolManager() {
        _onlyPoolManager();
        _;
    }

    /// @notice internal function requires caller is PoolManager
    function _onlyPoolManager() internal view {
        require(msg.sender == address(POOL_MANAGER), CALLER_NOT_POOL_MANAGER());
    }

    /// @notice Validates the deployed hook
    /// @param _this A Hook contract
    function validateHookAddress(IHooks _this) internal pure {
        Hooks.validateHookPermissions(_this, getHookPermissions());
    }

    /// @notice Returns activated hook permissions
    /// @return permissions active hook perssions
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // true
            afterInitialize: true, // true
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // prevent liquidity adds
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // true
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // true
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    //////////////////////////
    ///////// Core ///////////
    //////////////////////////

    /// @notice The balance of remaining tokens to be filled by solver
    /// @param order The swap order
    /// @return amountGiven The amount supplied by swapper
    function getBalanceIn(Order memory order, bool zeroForOne) public view returns (uint256 amountGiven) {
        bytes32 orderId = keccak256(abi.encode(order));
        amountGiven = balancesIn[orderId][zeroForOne];
    }

    /// @notice The balance of remaining tokens to be taken by swapper
    /// @param order The order submitted by swapper
    /// @return amountRemaining The remaining amount output tokens to be solved by filler
    function getBalanceOut(Order memory order, bool zeroForOne) public view returns (uint256 amountRemaining) {
        bytes32 orderId = keccak256(abi.encode(order));
        amountRemaining = balancesOut[orderId][zeroForOne];
    }

    //////////////////////////
    ///// HOOK ACTIVATED /////
    //////////////////////////

    /// @inheritdoc IHooks
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        // ignores sqrtPrice
        // input validation is done during swap order with tick validations on amountIn and amountOut

        /// @dev only owner of this hook is allowed to initialize pools
        require(sender == owner, "NOT HOOK OWNER");
        require(address(key.hooks) == address(this));
        /// @dev require a minimum fee
        require(key.fee >= 1_2000, "FEE SET TOO LOW"); // 1.2 %

        return this.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterInitialize(address sender, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        // ignores sqrtPrice and tick
        // input validation of is done during swap order with tick validations on amountIn and amountOut

        /// @dev only owner of this contract can modify pools initialization
        require(sender == owner);
        /// @dev store poolId
        pools[key.toId()] = key;

        return this.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Order memory order = abi.decode(hookData, (Order));
        if (sender != router) revert("UNTRUSTED ROUTER");

        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(order.tick);
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;

        if (params.amountSpecified > 0) {
            // EXACT OUTPUT: user wants this many tokens out
            // Calculate how much they need to pay
            amountOut = uint256(params.amountSpecified);

            // Back-calculate net input needed for this output
            uint256 amountInAfterFee;
            if (params.zeroForOne) {
                // Want token1, pay token0: amountIn = amountOut / price
                amountInAfterFee = FullMath.mulDivRoundingUp(
                    FullMath.mulDivRoundingUp(amountOut, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice
                );
            } else {
                // Want token0, pay token1: amountIn = amountOut * price
                amountInAfterFee = FullMath.mulDivRoundingUp(
                    FullMath.mulDivRoundingUp(amountOut, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96
                );
            }

            // Gross up to include fee (round up)
            amountIn = FullMath.mulDivRoundingUp(amountInAfterFee, 1_000_000, 1_000_000 - key.fee);
            feeAmount = amountIn - amountInAfterFee;
        } else {
            // EXACT INPUT: user specifies how much they're giving
            amountIn = uint256(-params.amountSpecified);

            // Take fee first (round-up - protocol keeps more)
            feeAmount = FullMath.mulDivRoundingUp(amountIn, key.fee, 1_000_000);
            uint256 amountInAfterFee = amountIn - feeAmount;

            // Compute output from net input (round down)
            if (params.zeroForOne) {
                // Selling token0 for token1: amountOut = amountIn * price
                amountOut = FullMath.mulDiv(
                    FullMath.mulDiv(amountInAfterFee, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96
                );
            } else {
                amountOut = FullMath.mulDiv(
                    FullMath.mulDiv(amountInAfterFee, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice
                );
            }

            // Slippage protection
            require(amountOut >= order.amountOut, "SLIPPAGE");

            // Take gross input
            input.take(POOL_MANAGER, address(this), amountIn, true);

            // Record order for filler
            bytes32 orderId = keccak256(abi.encode(order));
            balancesIn[orderId][params.zeroForOne] += amountIn;
            balancesOut[orderId][params.zeroForOne] += amountOut;

            emit Swap(orderId, order);

            BeforeSwapDelta beforeSwapDelta;
            if (params.amountSpecified < 0) {
                // EXACT INPUT: hook takes from the specified (input) side
                // deltaSpecified = positive = hook takes specified tokens
                beforeSwapDelta = toBeforeSwapDelta(int128(-params.amountSpecified), 0);
            } else {
                // EXACT OUTPUT: specified = output token, unspecified = input token
                // deltaSpecified = -amountSpecified to zero out AMM
                // deltaUnpecified = +amountIn to account for the input we're taking
                beforeSwapDelta = toBeforeSwapDelta(int128(-params.amountSpecified), int128(int256(amountIn)));
            }
            return (this.beforeSwap.selector, beforeSwapDelta, key.fee);
        }
    }

    ///////////////////////////
    ///// HOOK NOT IN USE /////
    ///////////////////////////

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HOOK_NOT_IN_USE();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert PROVIDE_LIQUIDITY_BY_SOLVING();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HOOK_NOT_IN_USE();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HOOK_NOT_IN_USE();
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, int128)
    {
        revert HOOK_NOT_IN_USE();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HOOK_NOT_IN_USE();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HOOK_NOT_IN_USE();
    }
}
