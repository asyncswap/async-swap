// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Order, OrderLibrary} from "src/types/Order.sol";

/// @notice Malicious ERC-20 that re-enters AsyncSwap.fill() during transferFrom
contract ReentrantToken {
    string public name = "ReentrantToken";
    string public symbol = "REENTER";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    AsyncSwap public target;
    Order public attackOrder;
    bool public attackZeroForOne;
    uint256 public attackAmount;
    bool public armed;
    uint256 public reentrancyCalls;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (armed) {
            armed = false;
            reentrancyCalls++;
            try target.fill(attackOrder, attackZeroForOne, attackAmount) {
                reentrancyCalls += 100; // marks success — would be a bug
            } catch {
                // expected: revert due to state already updated
            }
        }

        return true;
    }

    function arm(AsyncSwap _target, Order memory _order, bool _zeroForOne, uint256 _amount) external {
        target = _target;
        attackOrder = _order;
        attackZeroForOne = _zeroForOne;
        attackAmount = _amount;
        armed = true;
    }
}

/// @notice Malicious swapper contract that re-enters fill() when receiving native ETH
contract ReentrantSwapper {
    AsyncSwap public target;
    Order public attackOrder;
    bool public attackZeroForOne;
    uint256 public attackAmount;
    bool public armed;
    uint256 public reentrancyCalls;

    function arm(AsyncSwap _target, Order memory _order, bool _zeroForOne, uint256 _amount) external {
        target = _target;
        attackOrder = _order;
        attackZeroForOne = _zeroForOne;
        attackAmount = _amount;
        armed = true;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            reentrancyCalls++;
            try target.fill{value: attackAmount}(attackOrder, attackZeroForOne, attackAmount) {
                reentrancyCalls += 100; // marks success — would be a bug
            } catch {
                // expected: revert due to state already updated
            }
        }
    }
}

contract AsyncSwapReentrancyTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using OrderLibrary for Order;

    AsyncSwap hook;

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
        hook.unpause();
    }

    function _netInput(uint256 amount) internal pure returns (uint256) {
        uint256 fee = FullMath.mulDivRoundingUp(amount, HOOK_FEE, 1_000_000);
        return amount - fee;
    }

    // ================================================================
    // Malicious ERC-20 output token reentrancy
    // ================================================================

    /// @notice A filler using a malicious output token cannot re-enter fill() to double-fill.
    ///         State (balancesOut/balancesIn) is updated BEFORE _deliverOutput, so a reentrant
    ///         fill() sees zero remaining and reverts with ORDER_ALREADY_FILLED.
    function test_fill_reentrancy_via_malicious_token_reverts() public {
        ReentrantToken malToken = new ReentrantToken();

        // Deploy a real input token
        MockERC20 inputToken = new MockERC20("Input", "IN", 18);
        address inputAddr = address(inputToken);
        address outputAddr = address(malToken);

        (Currency c0, Currency c1) = inputAddr < outputAddr
            ? (Currency.wrap(inputAddr), Currency.wrap(outputAddr))
            : (Currency.wrap(outputAddr), Currency.wrap(inputAddr));

        PoolKey memory customKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId customPoolId = customKey.toId();
        manager.initialize(customKey, SQRT_PRICE_1_1);

        bool zeroForOne = Currency.unwrap(c0) == inputAddr;

        // Mint input tokens and approve the router
        uint256 swapAmount = 10e18;
        inputToken.mint(address(this), swapAmount);
        inputToken.approve(address(hook.router()), type(uint256).max);

        // Create an order
        Order memory order = Order({poolId: customPoolId, swapper: address(this), tick: ORDER_TICK});
        hook.swap(customKey, zeroForOne, swapAmount, ORDER_TICK, 0, 0);

        bytes32 orderId = order.toId();
        uint256 expectedOut = hook.getBalanceOut(orderId, zeroForOne);
        require(expectedOut > 0, "order not created");

        // Setup the malicious token as filler
        address filler = address(malToken);
        malToken.mint(filler, expectedOut * 2);
        vm.prank(filler);
        malToken.approve(address(hook), type(uint256).max);

        // Arm reentrancy
        malToken.arm(hook, order, zeroForOne, expectedOut);

        // Fill — triggers reentrancy attempt inside transferFrom
        vm.prank(filler);
        hook.fill(order, zeroForOne, expectedOut);

        // Verify: filled once, reentrant call reverted
        assertEq(hook.getBalanceOut(orderId, zeroForOne), 0, "order should be fully filled");
        assertEq(malToken.reentrancyCalls(), 1, "reentrancy should have been attempted once");
        assertTrue(malToken.reentrancyCalls() < 100, "reentrant fill must not succeed");
    }

    // ================================================================
    // Native ETH output reentrancy
    // ================================================================

    /// @notice A malicious swapper contract that re-enters fill() via receive() when receiving
    ///         native ETH output. The hook sends ETH to the swapper via Currency.transfer inside
    ///         _deliverOutput — a receive() callback can attempt to re-enter fill().
    ///         State is already updated so the reentrant call should revert.
    function test_fill_reentrancy_via_native_eth_receive_reverts() public {
        // Deploy malicious swapper and a regular ERC-20 for the input side
        ReentrantSwapper malSwapper = new ReentrantSwapper();
        MockERC20 token1 = new MockERC20("Token One", "TK1", 18);

        // Pool: currency0 = native ETH (address(0)), currency1 = token1
        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId nativePoolId = nativeKey.toId();
        manager.initialize(nativeKey, SQRT_PRICE_1_1);

        // Malicious swapper creates an order: swaps token1 (input) for ETH (output)
        // zeroForOne=false means: input=currency1(token1), output=currency0(ETH)
        uint256 swapAmount = 1e18;
        token1.mint(address(malSwapper), swapAmount);

        vm.startPrank(address(malSwapper));
        token1.approve(address(hook.router()), type(uint256).max);
        hook.swap(nativeKey, false, swapAmount, ORDER_TICK, 0, 0);
        vm.stopPrank();

        Order memory order = Order({poolId: nativePoolId, swapper: address(malSwapper), tick: ORDER_TICK});
        bytes32 orderId = order.toId();
        uint256 expectedOut = hook.getBalanceOut(orderId, false);
        require(expectedOut > 0, "order not created");

        // Arm the malicious swapper to re-enter on ETH receive
        vm.deal(address(malSwapper), expectedOut * 2);
        malSwapper.arm(hook, order, false, expectedOut);

        // Filler sends ETH to fill the order — ETH goes to malSwapper's receive()
        address filler = makeAddr("ethFiller");
        vm.deal(filler, expectedOut);

        vm.prank(filler);
        hook.fill{value: expectedOut}(order, false, expectedOut);

        // Verify: filled once, reentrant call reverted
        assertEq(hook.getBalanceOut(orderId, false), 0, "order should be fully filled");
        assertEq(malSwapper.reentrancyCalls(), 1, "reentrancy should have been attempted once");
        assertTrue(malSwapper.reentrancyCalls() < 100, "reentrant fill must not succeed");
    }
}
