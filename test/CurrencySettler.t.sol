// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {CurrencySettler} from "../src/libraries/CurrencySettler.sol";

contract CurrencySettlerTest is Test {
    PoolManager manager;
    CurrencySettlerHarness harness;
    MockERC20 token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        manager = new PoolManager(address(this));
        harness = new CurrencySettlerHarness(manager);
        token = new MockERC20("Token", "TKN", 18);

        token.mint(alice, 100e18);
        vm.deal(alice, 100 ether);

        vm.prank(alice);
        token.approve(address(harness), type(uint256).max);
    }

    function test_settleNativeAndTakeNative() public {
        uint256 amount = 1 ether;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        harness.settleNativeAndTake{value: amount}(bob, amount);

        assertEq(bob.balance - bobBefore, amount, "native take failed");
    }

    function test_settleErc20FromPayerAndTake() public {
        uint256 amount = 5e18;
        uint256 bobBefore = token.balanceOf(bob);
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        harness.settleErc20FromPayerAndTake(Currency.wrap(address(token)), alice, bob, amount);

        assertEq(token.balanceOf(bob) - bobBefore, amount, "erc20 take failed");
        assertEq(aliceBefore - token.balanceOf(alice), amount, "payer should fund settle");
    }

    function test_settleErc20FromSelfAndTake() public {
        uint256 amount = 3e18;
        token.mint(address(harness), amount);
        uint256 bobBefore = token.balanceOf(bob);

        harness.settleErc20FromSelfAndTake(Currency.wrap(address(token)), bob, amount);

        assertEq(token.balanceOf(bob) - bobBefore, amount, "self-funded settle/take failed");
    }

    function test_settleAndMintClaims() public {
        uint256 amount = 7e18;
        uint256 claimsBefore = manager.balanceOf(bob, Currency.wrap(address(token)).toId());

        vm.prank(alice);
        harness.settleAndMintClaims(Currency.wrap(address(token)), alice, bob, amount);

        assertEq(
            manager.balanceOf(bob, Currency.wrap(address(token)).toId()) - claimsBefore, amount, "claims mint failed"
        );
    }

    function test_burnClaimsAndTake() public {
        uint256 amount = 4e18;

        vm.prank(alice);
        harness.settleAndMintClaims(Currency.wrap(address(token)), alice, address(harness), amount);
        assertEq(manager.balanceOf(address(harness), Currency.wrap(address(token)).toId()), amount, "claims not minted");

        uint256 bobBefore = token.balanceOf(bob);
        harness.burnClaimsAndTake(Currency.wrap(address(token)), address(harness), bob, amount);

        assertEq(manager.balanceOf(address(harness), Currency.wrap(address(token)).toId()), 0, "claims not burned");
        assertEq(token.balanceOf(bob) - bobBefore, amount, "burn and take failed");
    }
}

contract CurrencySettlerHarness is IUnlockCallback {
    using CurrencySettler for Currency;

    PoolManager internal immutable manager;

    enum Action {
        SettleTake,
        SettleMintClaims,
        BurnTake
    }

    struct CallbackData {
        Action action;
        Currency currency;
        address payer;
        address recipient;
        uint256 amount;
        bool burn;
        bool claims;
    }

    constructor(PoolManager _manager) {
        manager = _manager;
    }

    function settleNativeAndTake(address recipient, uint256 amount) external payable {
        require(msg.value == amount, "BAD_VALUE");
        manager.unlock(
            abi.encode(
                CallbackData({
                    action: Action.SettleTake,
                    currency: Currency.wrap(address(0)),
                    payer: address(this),
                    recipient: recipient,
                    amount: amount,
                    burn: false,
                    claims: false
                })
            )
        );
    }

    function settleErc20FromPayerAndTake(Currency currency, address payer, address recipient, uint256 amount) external {
        manager.unlock(
            abi.encode(
                CallbackData({
                    action: Action.SettleTake,
                    currency: currency,
                    payer: payer,
                    recipient: recipient,
                    amount: amount,
                    burn: false,
                    claims: false
                })
            )
        );
    }

    function settleErc20FromSelfAndTake(Currency currency, address recipient, uint256 amount) external {
        manager.unlock(
            abi.encode(
                CallbackData({
                    action: Action.SettleTake,
                    currency: currency,
                    payer: address(this),
                    recipient: recipient,
                    amount: amount,
                    burn: false,
                    claims: false
                })
            )
        );
    }

    function settleAndMintClaims(Currency currency, address payer, address recipient, uint256 amount) external {
        manager.unlock(
            abi.encode(
                CallbackData({
                    action: Action.SettleMintClaims,
                    currency: currency,
                    payer: payer,
                    recipient: recipient,
                    amount: amount,
                    burn: false,
                    claims: true
                })
            )
        );
    }

    function burnClaimsAndTake(Currency currency, address payer, address recipient, uint256 amount) external {
        manager.unlock(
            abi.encode(
                CallbackData({
                    action: Action.BurnTake,
                    currency: currency,
                    payer: payer,
                    recipient: recipient,
                    amount: amount,
                    burn: true,
                    claims: false
                })
            )
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "ONLY_PM");

        CallbackData memory cb = abi.decode(data, (CallbackData));
        if (cb.action == Action.SettleTake || cb.action == Action.SettleMintClaims) {
            cb.currency.settle(manager, cb.payer, cb.amount, false);
            cb.currency.take(manager, cb.recipient, cb.amount, cb.claims);
        } else {
            cb.currency.settle(manager, cb.payer, cb.amount, true);
            cb.currency.take(manager, cb.recipient, cb.amount, false);
        }
        return "";
    }

    receive() external payable {}
}
