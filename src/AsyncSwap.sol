// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract AsyncSwap layout at 1000 is IHooks {
    /// @notice The PoolManager contract address
    IPoolManager public immutable POOL_MANAGER;

    /// @notice The minimum fee charged by the protocol in bips 1.2%
    uint24 public minimumFee = 1_2000;

    /// @notice The Owner
    address public owner;

    /// @notice Swap orders for input token0
    /// @dev balancesIn is initialized by swapper and mutated by filler
    mapping(address swapper => mapping(bool zeroForOne => uint256 amountGiven)) balancesIn;
    /// @notice Swap orders for output token1
    /// @dev balancesOut is initialized by swapper and mutated by filler
    mapping(address swapper => mapping(bool zeroForOne => uint256 amountTaken)) balancesOut;

    /// @param owner creator of order
    /// @param deadline order expiration time
    /// @param zeroForOne direction of order
    /// @param sqrtPrice price to execute order
    /// @param amount amount of token
    struct Order {
        address sender;
        uint64 deadline;
        bool zeroForOne;
        uint160 sqrtPrice;
        uint256 amountIn;
        uint256 amountOut;
    }

    /// @notice A swap event
    event Swap(bytes32 orderId, Order order);

    /// @notice Error if caller is not poolmanager address
    error CALLER_NOT_POOL_MANAGER();

    /// @notice Error for method not implemented
    error HOOK_NOT_IN_USE();

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
            afterAddLiquidity: false,
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
    ///// HOOK ACTIVATED /////
    //////////////////////////

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        require(sender == owner, "NOT HOOK OWNER");
        require(address(key.hooks) == address(this));
        require(key.fee >= 1_2000, "FEE SET TOO LOW"); // 1.2 %
        sqrtPriceX96;
        return this.beforeInitialize.selector;
    }

    function getLatestPrice(Currency currency) public returns (uint256) {}

    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        require(sender == owner);
        key;
        sqrtPriceX96;
        tick;
        return this.afterInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {}

    ///////////////////////////
    ///// HOOK NOT IN USE /////
    ///////////////////////////

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HOOK_NOT_IN_USE();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HOOK_NOT_IN_USE();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HOOK_NOT_IN_USE();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HOOK_NOT_IN_USE();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HOOK_NOT_IN_USE();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HOOK_NOT_IN_USE();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HOOK_NOT_IN_USE();
    }
}
