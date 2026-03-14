// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {IntentAuth} from "../src/IntentAuth.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

contract AsyncSwapGovernanceTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AsyncSwap hook;
    PoolKey poolKey;
    PoolId poolId;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint24 constant INITIAL_MIN_FEE = 1_2000;
    int24 constant TICK_SPACING = 240;
    int24 constant ORDER_TICK = 0;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(HOOK_FLAGS);
        deployCodeTo("AsyncSwap.sol:AsyncSwap", abi.encode(address(manager), address(this)), hookAddr);
        hook = AsyncSwap(hookAddr);

        address hookRouter = address(hook.router());
        MockERC20(Currency.unwrap(currency0)).approve(hookRouter, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(hookRouter, type(uint256).max);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0)).mint(alice, 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(alice, 100e18);
        MockERC20(Currency.unwrap(currency0)).mint(bob, 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(bob, 100e18);

        vm.prank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(hookRouter, type(uint256).max);
        vm.prank(alice);
        MockERC20(Currency.unwrap(currency1)).approve(hookRouter, type(uint256).max);
        vm.prank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(hookRouter, type(uint256).max);
        vm.prank(bob);
        MockERC20(Currency.unwrap(currency1)).approve(hookRouter, type(uint256).max);
    }

    function _swapAs(address user, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(user);
        hook.swap(poolKey, zeroForOne, amountIn, ORDER_TICK, 0);
    }

    function test_transferOwnership_setsPendingOwner() public {
        hook.transferOwnership(bob);

        assertEq(hook.protocolOwner(), address(this));
        assertEq(hook.pendingOwner(), bob);
    }

    function test_transferOwnership_nonOwner_reverts() public {
        vm.prank(mallory);
        vm.expectRevert(bytes("NOT OWNER"));
        hook.transferOwnership(bob);
    }

    function test_acceptOwnership_transfersAndClearsPending() public {
        hook.transferOwnership(bob);

        vm.prank(bob);
        hook.acceptOwnership();

        assertEq(hook.protocolOwner(), bob);
        assertEq(hook.pendingOwner(), address(0));
    }

    function test_acceptOwnership_nonPending_reverts() public {
        hook.transferOwnership(bob);

        vm.prank(mallory);
        vm.expectRevert(IntentAuth.NOT_PENDING_OWNER.selector);
        hook.acceptOwnership();
    }

    function test_setTreasury_updatesTreasury() public {
        hook.setTreasury(treasury);
        assertEq(hook.treasury(), treasury);
    }

    function test_setTreasury_nonOwner_reverts() public {
        vm.prank(mallory);
        vm.expectRevert(bytes("NOT OWNER"));
        hook.setTreasury(treasury);
    }

    function test_setMinimumFee_updatesMinimum() public {
        hook.setMinimumFee(15_000);
        assertEq(hook.minimumFee(), 15_000);
    }

    function test_setMinimumFee_nonOwner_reverts() public {
        vm.prank(mallory);
        vm.expectRevert(bytes("NOT OWNER"));
        hook.setMinimumFee(15_000);
    }

    function test_setPoolFee_updatesPoolFee() public {
        hook.setPoolFee(poolId, 15_000);
        assertEq(hook.poolFee(poolId), 15_000);
    }

    function test_setPoolFee_nonOwner_reverts() public {
        vm.prank(mallory);
        vm.expectRevert(bytes("NOT OWNER"));
        hook.setPoolFee(poolId, 15_000);
    }

    function test_setPoolFee_belowMinimum_reverts() public {
        vm.expectRevert(bytes("FEE BELOW MINIMUM"));
        hook.setPoolFee(poolId, INITIAL_MIN_FEE - 1);
    }

    function test_setPoolFee_aboveMax_reverts() public {
        vm.expectRevert(bytes("FEE TOO HIGH"));
        hook.setPoolFee(poolId, 1_000_001);
    }

    function test_setFeeRefundToggle_updatesMode() public {
        hook.setFeeRefundToggle(true);
        assertTrue(hook.feeRefundToggle());
    }

    function test_setFeeRefundToggle_nonOwner_reverts() public {
        vm.prank(mallory);
        vm.expectRevert(bytes("NOT OWNER"));
        hook.setFeeRefundToggle(true);
    }

    function test_afterInitialize_setsInitialPoolFeeToMinimum() public view {
        assertEq(hook.poolFee(poolId), hook.minimumFee());
    }

    function test_claimFees_treasuryNotSet_reverts() public {
        _swapAs(alice, true, 1e18);

        vm.expectRevert(IntentAuth.TREASURY_NOT_SET.selector);
        hook.claimFees(currency0);
    }

    function test_claimFees_noFeesAccrued_reverts() public {
        hook.setTreasury(treasury);

        vm.expectRevert(IntentAuth.NO_FEES_ACCRUED.selector);
        hook.claimFees(currency0);
    }

    function test_claimFees_transfersAccruedFeesToTreasury() public {
        uint256 amountIn = 1e18;
        hook.setTreasury(treasury);

        _swapAs(alice, true, amountIn);

        uint256 fee = FullMath.mulDivRoundingUp(amountIn, hook.poolFee(poolId), 1_000_000);
        assertEq(hook.accruedFees(currency0), fee);

        uint256 treasuryBefore = currency0.balanceOf(treasury);
        hook.claimFees(currency0);

        assertEq(currency0.balanceOf(treasury) - treasuryBefore, fee, "treasury did not receive fees");
        assertEq(hook.accruedFees(currency0), 0, "fees not cleared");
    }

    function test_updatedPoolFee_changesFutureAccrual() public {
        uint256 amountIn = 1e18;
        hook.setTreasury(treasury);

        _swapAs(alice, true, amountIn);
        uint256 fee1 = hook.accruedFees(currency0);

        hook.setPoolFee(poolId, 20_000);
        _swapAs(bob, true, amountIn);

        uint256 fee2 = FullMath.mulDivRoundingUp(amountIn, 20_000, 1_000_000);
        assertEq(hook.accruedFees(currency0), fee1 + fee2);
    }

    function test_pause_and_unpause() public {
        hook.pause();
        assertTrue(hook.paused());

        hook.unpause();
        assertFalse(hook.paused());
    }

    function test_pause_nonOwner_reverts() public {
        vm.prank(mallory);
        vm.expectRevert(bytes("NOT OWNER"));
        hook.pause();
    }

    function test_unpause_nonOwner_reverts() public {
        hook.pause();
        vm.prank(mallory);
        vm.expectRevert(bytes("NOT OWNER"));
        hook.unpause();
    }
}
