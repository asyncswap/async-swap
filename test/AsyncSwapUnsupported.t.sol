// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {AsyncRouter} from "../src/AsyncRouter.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/// @notice Tests that adding liquidity is blocked (afterAddLiquidity flag is enabled to reject LPs).
contract AsyncSwapUnsupportedTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AsyncSwap hook;
    PoolKey poolKey;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint24 constant HOOK_FEE = 1_2000;
    int24 constant TICK_SPACING = 240;

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
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });

        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function _initCustomPool(address token0Addr, address token1Addr)
        internal
        returns (PoolKey memory customKey, PoolId customPoolId, bool zeroForOne)
    {
        (Currency c0, Currency c1) = token0Addr < token1Addr
            ? (Currency.wrap(token0Addr), Currency.wrap(token1Addr))
            : (Currency.wrap(token1Addr), Currency.wrap(token0Addr));

        customKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        customPoolId = customKey.toId();
        zeroForOne = Currency.unwrap(c0) == token0Addr;

        manager.initialize(customKey, SQRT_PRICE_1_1);
    }

    // ========================================
    // Hook address flags match permissions
    // ========================================

    function test_validateHookPermissions() public view {
        // Validates that the hook address has the correct flag bits for the declared permissions.
        // This exercises the same check as the internal validateHookAddress().
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
    }

    // ========================================
    // Adding liquidity is blocked
    // ========================================

    function test_addLiquidity_reverts() public {
        // afterAddLiquidity flag is enabled — PM calls it, hook reverts with PROVIDE_LIQUIDITY_BY_SOLVING
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -TICK_SPACING, tickUpper: TICK_SPACING, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    function test_addLiquidity_differentRange_reverts() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 10,
                tickUpper: TICK_SPACING * 10,
                liquidityDelta: 100e18,
                salt: 0
            }),
            ""
        );
    }

    function test_addLiquidity_smallAmount_reverts() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -TICK_SPACING, tickUpper: TICK_SPACING, liquidityDelta: 1, salt: 0}),
            ""
        );
    }

    // ========================================
    // Stub hooks — mocked PM caller for coverage
    // ========================================

    function test_beforeAddLiquidity_reverts() public {
        vm.prank(address(manager));
        vm.expectRevert(AsyncSwap.HOOK_NOT_IN_USE.selector);
        hook.beforeAddLiquidity(
            address(this), poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}), ""
        );
    }

    function test_afterAddLiquidity_reverts() public {
        vm.prank(address(manager));
        vm.expectRevert(AsyncSwap.PROVIDE_LIQUIDITY_BY_SOLVING.selector);
        hook.afterAddLiquidity(
            address(this), poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            BalanceDelta.wrap(0), BalanceDelta.wrap(0), ""
        );
    }

    function test_beforeRemoveLiquidity_reverts() public {
        vm.prank(address(manager));
        vm.expectRevert(AsyncSwap.HOOK_NOT_IN_USE.selector);
        hook.beforeRemoveLiquidity(
            address(this), poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0}), ""
        );
    }

    function test_afterRemoveLiquidity_reverts() public {
        vm.prank(address(manager));
        vm.expectRevert(AsyncSwap.HOOK_NOT_IN_USE.selector);
        hook.afterRemoveLiquidity(
            address(this), poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0}),
            BalanceDelta.wrap(0), BalanceDelta.wrap(0), ""
        );
    }

    function test_afterSwap_reverts() public {
        vm.prank(address(manager));
        vm.expectRevert(AsyncSwap.HOOK_NOT_IN_USE.selector);
        hook.afterSwap(
            address(this), poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0}),
            BalanceDelta.wrap(0), ""
        );
    }

    function test_beforeDonate_reverts() public {
        vm.prank(address(manager));
        vm.expectRevert(AsyncSwap.HOOK_NOT_IN_USE.selector);
        hook.beforeDonate(address(this), poolKey, 1e18, 1e18, "");
    }

    function test_afterDonate_reverts() public {
        vm.prank(address(manager));
        vm.expectRevert(AsyncSwap.HOOK_NOT_IN_USE.selector);
        hook.afterDonate(address(this), poolKey, 1e18, 1e18, "");
    }

    function test_feeOnTransferInput_revertsAndCreatesNoOrder() public {
        FeeOnTransferInputToken inputToken = new FeeOnTransferInputToken("Taxed In", "TIN", 18, 1000);
        MockERC20 outputToken = new MockERC20("Out", "OUT", 18);

        inputToken.mint(address(this), 100e18);
        inputToken.approve(address(hook.router()), type(uint256).max);

        (PoolKey memory customKey, PoolId customPoolId, bool zeroForOne) =
            _initCustomPool(address(inputToken), address(outputToken));

        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: customPoolId, swapper: address(this), tick: 0});

        vm.expectRevert(AsyncRouter.UNSUPPORTED_INPUT_TOKEN.selector);
        hook.swap(customKey, zeroForOne, 10e18, 0, 0, 0);

        assertEq(hook.getBalanceIn(order, zeroForOne), 0, "input should not be recorded");
        assertEq(hook.getBalanceOut(order, zeroForOne), 0, "output should not be recorded");
    }

    function test_beforeSwap_untrustedRouter_reverts() public {
        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: poolKey.toId(), swapper: address(this), tick: 0});

        vm.prank(address(manager));
        vm.expectRevert(bytes("UNTRUSTED ROUTER"));
        hook.beforeSwap(
            address(this),
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            abi.encode(order, uint256(0))
        );
    }

    function test_falseReturnInput_revertsAndCreatesNoOrder() public {
        FalseReturnInputToken inputToken = new FalseReturnInputToken("False In", "FIN", 18);
        MockERC20 outputToken = new MockERC20("Out", "OUT", 18);

        inputToken.mint(address(this), 100e18);
        inputToken.approve(address(hook.router()), type(uint256).max);

        (PoolKey memory customKey, PoolId customPoolId, bool zeroForOne) =
            _initCustomPool(address(inputToken), address(outputToken));

        AsyncSwap.Order memory order = AsyncSwap.Order({poolId: customPoolId, swapper: address(this), tick: 0});

        vm.expectRevert(AsyncRouter.INPUT_TRANSFER_FAILED.selector);
        hook.swap(customKey, zeroForOne, 10e18, 0, 0, 0);

        assertEq(hook.getBalanceIn(order, zeroForOne), 0, "input should not be recorded");
        assertEq(hook.getBalanceOut(order, zeroForOne), 0, "output should not be recorded");
    }
}

contract FeeOnTransferInputToken is MockERC20 {
    uint256 internal immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_)
        MockERC20(name_, symbol_, decimals_)
    {
        feeBps = feeBps_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        uint256 fee = amount * feeBps / 10_000;
        uint256 received = amount - fee;

        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += received;
            totalSupply -= fee;
        }

        emit Transfer(from, to, received);
        if (fee > 0) emit Transfer(from, address(0), fee);
        return true;
    }
}

contract FalseReturnInputToken is MockERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        emit Transfer(from, to, 0);
        return false;
    }
}
