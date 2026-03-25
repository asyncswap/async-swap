// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {AsyncToken} from "../src/governance/AsyncToken.sol";
import {AsyncGovernor} from "../src/governance/AsyncGovernor.sol";
import {AsyncRouter} from "../src/AsyncRouter.sol";
import {IntentAuth} from "../src/IntentAuth.sol";
import {IAsyncSwapOracle} from "../src/interfaces/IAsyncSwapOracle.sol";
import {ChronicleOracleAdapter, IChronicle, ISelfKisser} from "../src/oracle/ChronicleOracleAdapter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract E2EWalkthrough is Script {
    using PoolIdLibrary for PoolKey;
    uint24 constant MINIMUM_FEE = 1_2000; // PPM{1} 1.2% default minimum fee

    function run() public {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address poolManagerAddr = vm.envAddress("POOLMANAGER_ADDRESS");
        address usdcAddr = vm.envAddress("TOKEN1_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address filler = vm.envAddress("FILLER_ADDRESS");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        address chronicleAddr = vm.envOr("CHRONICLE_ORACLE", address(0));
        address selfKisserAddr = vm.envOr("CHRONICLE_SELF_KISSER", address(0));

        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        MockERC20 usdc = MockERC20(usdcAddr);

        vm.startBroadcast(deployer);

        // =============================================
        // STEP 1: Deploy AsyncSwap
        // =============================================
        console2.log("=== STEP 1: Deploy AsyncSwap ===");

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        (address minedAddr, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY, flags, type(AsyncSwap).creationCode, abi.encode(poolManagerAddr, deployer, MINIMUM_FEE)
        );
        AsyncSwap hook = new AsyncSwap{salt: salt}(poolManager, deployer, MINIMUM_FEE);
        require(address(hook) == minedAddr, "HOOK_ADDRESS_MISMATCH");
        console2.log("AsyncSwap:", address(hook));
        console2.log("Router:", address(hook.router()));

        // =============================================
        // STEP 2: Deploy Governance
        // =============================================
        console2.log("=== STEP 2: Deploy Governance ===");

        AsyncToken govToken = new AsyncToken(deployer);
        console2.log("AsyncToken:", address(govToken));

        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(60, proposers, executors, deployer);
        console2.log("Timelock:", address(timelock));

        AsyncGovernor governor = new AsyncGovernor(govToken, timelock, 1, 10, 100e18, 4);
        console2.log("Governor:", address(governor));
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));

        // =============================================
        // STEP 3: Configure Protocol
        // =============================================
        console2.log("=== STEP 3: Configure Protocol ===");

        hook.setTreasury(treasury);
        hook.setRewardToken(govToken);
        govToken.setMinter(address(hook));
        console2.log("Treasury:", treasury);
        console2.log("Hook is token minter");

        // =============================================
        // STEP 4: Deploy ERC20 Demo Tokens + Initialize Multiple Pools
        // =============================================
        console2.log("=== STEP 4: Initialize Pools ===");

        // Pool A: native / USDC
        PoolKey memory poolA = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(usdcAddr),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 240,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(poolA, 79228162514264337593543950336);
        console2.log("Pool A (native/USDC) initialized");

        // Pool B: tokenX / tokenY (fresh ERC20s)
        MockERC20 tokenX = new MockERC20("Token X", "TKX", 18);
        MockERC20 tokenY = new MockERC20("Token Y", "TKY", 18);
        (Currency c0, Currency c1) = address(tokenX) < address(tokenY)
            ? (Currency.wrap(address(tokenX)), Currency.wrap(address(tokenY)))
            : (Currency.wrap(address(tokenY)), Currency.wrap(address(tokenX)));

        PoolKey memory poolB = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 240,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(poolB, 79228162514264337593543950336);
        console2.log("Pool B (tokenX/tokenY) initialized");
        console2.log("TokenX:", address(tokenX));
        console2.log("TokenY:", address(tokenY));

        // =============================================
        // STEP 5: Swap on Pool A (native/USDC)
        // =============================================
        console2.log("=== STEP 5: Swap on Pool A (native/USDC) ===");

        uint256 swapAmountA = 0.001 ether;
        hook.swap{value: swapAmountA}(poolA, true, swapAmountA, 0, 0, 0);

        AsyncSwap.Order memory orderA = AsyncSwap.Order({poolId: poolA.toId(), swapper: deployer, tick: 0});
        console2.log("Order A balanceIn:", hook.getBalanceIn(orderA, true));
        console2.log("Order A balanceOut:", hook.getBalanceOut(orderA, true));
        console2.log("Deployer ASYNC balance:", govToken.balanceOf(deployer));

        // =============================================
        // STEP 6: Swap on Pool B (tokenX/tokenY) with deadline
        // =============================================
        console2.log("=== STEP 6: Swap on Pool B with deadline ===");

        tokenX.mint(deployer, 10e18);
        tokenY.mint(deployer, 10e18);
        address routerAddr = address(hook.router());

        // Approve the correct input token based on direction
        bool zfoB = address(tokenX) < address(tokenY); // true = tokenX is currency0
        if (zfoB) {
            tokenX.approve(routerAddr, type(uint256).max);
        } else {
            tokenY.approve(routerAddr, type(uint256).max);
        }

        uint256 deadline = block.timestamp + 300; // 5 minute deadline
        hook.swap(poolB, zfoB, 1e18, 0, 0, deadline);

        AsyncSwap.Order memory orderB = AsyncSwap.Order({poolId: poolB.toId(), swapper: deployer, tick: 0});
        console2.log("Order B balanceIn:", hook.getBalanceIn(orderB, zfoB));
        console2.log("Order B balanceOut:", hook.getBalanceOut(orderB, zfoB));
        console2.log("Order B deadline:", deadline);

        // =============================================
        // STEP 7: Fill Pool A order
        // =============================================
        console2.log("=== STEP 7: Fill Pool A order ===");
        vm.stopBroadcast();

        uint256 fillAmountA = hook.getBalanceOut(orderA, true);
        bytes32 fillerBalSlot = keccak256(abi.encode(filler, uint256(9)));
        vm.store(usdcAddr, fillerBalSlot, bytes32(fillAmountA));

        vm.startBroadcast(filler);
        usdc.approve(address(hook), type(uint256).max);
        hook.fill(orderA, true, fillAmountA);
        console2.log("Order A filled. Remaining:", hook.getBalanceOut(orderA, true));
        console2.log("Filler ASYNC balance:", govToken.balanceOf(filler));
        vm.stopBroadcast();

        // =============================================
        // STEP 8: Partial fill Pool B order
        // =============================================
        console2.log("=== STEP 8: Partial fill Pool B ===");

        uint256 remainingOutB = hook.getBalanceOut(orderB, zfoB);
        uint256 partialFillB = (remainingOutB + 1) / 2; // 50% minimum

        // Filler needs output token for pool B
        address outputTokenB = zfoB ? Currency.unwrap(c1) : Currency.unwrap(c0);
        vm.startBroadcast(deployer);
        MockERC20(outputTokenB).mint(filler, partialFillB);
        vm.stopBroadcast();

        vm.startBroadcast(filler);
        MockERC20(outputTokenB).approve(address(hook), type(uint256).max);
        hook.fill(orderB, zfoB, partialFillB);
        console2.log("Order B partially filled. Remaining out:", hook.getBalanceOut(orderB, zfoB));
        console2.log("Order B remaining in:", hook.getBalanceIn(orderB, zfoB));
        vm.stopBroadcast();

        // =============================================
        // STEP 9: Cancel remaining Pool B order (user cancel before expiry)
        // =============================================
        console2.log("=== STEP 9: User cancel Pool B ===");

        vm.startBroadcast(deployer);
        hook.cancelOrder(orderB, zfoB);
        console2.log("Order B cancelled. Remaining:", hook.getBalanceOut(orderB, zfoB));
        vm.stopBroadcast();

        // =============================================
        // STEP 10: Create expired order + keeper cancel
        // =============================================
        console2.log("=== STEP 10: Expired order + keeper cancel ===");

        vm.startBroadcast(deployer);
        uint256 shortDeadline = block.timestamp + 10;
        hook.swap{value: 0.0005 ether}(poolA, true, 0.0005 ether, 0, 0, shortDeadline);
        console2.log("Short-deadline order created, deadline:", shortDeadline);
        vm.stopBroadcast();

        // Warp past deadline
        vm.warp(block.timestamp + 20);
        console2.log("Time warped past deadline");

        AsyncSwap.Order memory expiredOrder = AsyncSwap.Order({poolId: poolA.toId(), swapper: deployer, tick: 0});

        vm.startBroadcast(keeper);
        hook.cancelOrder(expiredOrder, true);
        console2.log("Keeper cancelled expired order");
        console2.log("Keeper ASYNC balance:", govToken.balanceOf(keeper));
        vm.stopBroadcast();

        // =============================================
        // STEP 11: Change fee mode (fee refund toggle)
        // =============================================
        console2.log("=== STEP 11: Toggle fee refund mode ===");

        vm.startBroadcast(deployer);
        hook.setFeeRefundToggle(true);
        console2.log("Fee refund toggle enabled:", hook.feeRefundToggle());

        // Create order under new fee mode
        hook.swap{value: 0.002 ether}(poolA, true, 0.002 ether, 0, 0, 0);
        AsyncSwap.Order memory refundOrder = AsyncSwap.Order({poolId: poolA.toId(), swapper: deployer, tick: 0});
        console2.log("Refund-mode order balanceIn:", hook.getBalanceIn(refundOrder, true));
        console2.log("Refund-mode order balanceOut:", hook.getBalanceOut(refundOrder, true));

        // Cancel to show full refund (fee forgiven)
        hook.cancelOrder(refundOrder, true);
        console2.log("Refund-mode order cancelled (fee forgiven)");

        // Restore upfront mode
        hook.setFeeRefundToggle(false);
        console2.log("Fee refund toggle disabled");
        vm.stopBroadcast();

        // =============================================
        // STEP 12: Change pool fee via governance (timelock)
        // =============================================
        console2.log("=== STEP 12: Change pool fee via timelock ===");

        vm.startBroadcast(deployer);
        hook.transferOwnership(address(timelock));
        vm.stopBroadcast();

        vm.startBroadcast(address(timelock));
        hook.acceptOwnership();
        vm.stopBroadcast();

        console2.log("Ownership transferred to timelock");

        // Schedule setPoolFee via timelock
        vm.startBroadcast(deployer);
        bytes memory setFeeData = abi.encodeWithSelector(IntentAuth.setPoolFee.selector, poolA.toId(), uint24(20_000));
        timelock.schedule(address(hook), 0, setFeeData, bytes32(0), bytes32(0), 60);
        console2.log("setPoolFee scheduled via timelock");
        vm.stopBroadcast();

        // Warp past timelock delay
        vm.warp(block.timestamp + 61);

        vm.startBroadcast(deployer);
        timelock.execute(address(hook), 0, setFeeData, bytes32(0), bytes32(0));
        console2.log("setPoolFee executed. New fee:", hook.poolFee(poolA.toId()));
        vm.stopBroadcast();

        // =============================================
        // STEP 13: Deploy + configure Chronicle oracle
        // =============================================
        console2.log("=== STEP 13: Chronicle Oracle ===");

        if (chronicleAddr != address(0) && selfKisserAddr != address(0)) {
            vm.startBroadcast(deployer);
            ChronicleOracleAdapter adapter = new ChronicleOracleAdapter(ISelfKisser(selfKisserAddr), deployer);
            console2.log("Oracle adapter deployed:", address(adapter));

            adapter.setPoolConfig(
                poolA.toId(), IChronicle(chronicleAddr), false, 1_000_000, 1_000_000_000_000_000_000, true
            );
            console2.log("Pool A oracle configured");

            // Try reading the oracle
            try adapter.getQuoteSqrtPriceX96(poolA.toId()) returns (uint160 sqrtPrice, uint256 updatedAt) {
                console2.log("Oracle sqrtPriceX96:", sqrtPrice);
                console2.log("Oracle updatedAt:", updatedAt);
            } catch {
                console2.log("Oracle read failed (may need whitelist)");
            }

            // Configure oracle on AsyncSwap (need timelock now)
            bytes memory setOracleData = abi.encodeWithSelector(
                IntentAuth.setOracleConfig.selector,
                poolA.toId(),
                IAsyncSwapOracle(address(adapter)),
                uint32(300),
                uint16(100),
                uint16(5000),
                uint16(2500),
                uint16(2500)
            );
            timelock.schedule(address(hook), 0, setOracleData, bytes32(0), bytes32(uint256(1)), 60);
            vm.stopBroadcast();

            vm.warp(block.timestamp + 61);

            vm.startBroadcast(deployer);
            timelock.execute(address(hook), 0, setOracleData, bytes32(0), bytes32(uint256(1)));
            console2.log("Oracle config set on AsyncSwap via timelock");
            vm.stopBroadcast();
        } else {
            console2.log("Chronicle addresses not set - skipping oracle config");
        }

        // =============================================
        // STEP 14: Claim fees + surplus
        // =============================================
        console2.log("=== STEP 14: Claim fees + surplus ===");

        // Need timelock to call claimFees since it now owns the hook
        vm.startBroadcast(deployer);
        uint256 nativeFees = hook.accruedFees(Currency.wrap(address(0)));
        console2.log("Accrued native fees:", nativeFees);

        if (nativeFees > 0) {
            bytes memory claimData = abi.encodeWithSelector(IntentAuth.claimFees.selector, Currency.wrap(address(0)));
            timelock.schedule(address(hook), 0, claimData, bytes32(0), bytes32(uint256(2)), 60);
            vm.stopBroadcast();

            vm.warp(block.timestamp + 61);

            vm.startBroadcast(deployer);
            timelock.execute(address(hook), 0, claimData, bytes32(0), bytes32(uint256(2)));
            console2.log("Fees claimed to treasury via timelock");
        }
        vm.stopBroadcast();

        // =============================================
        // STEP 15: Pause + unpause
        // =============================================
        console2.log("=== STEP 15: Pause / Unpause ===");

        vm.startBroadcast(deployer);
        bytes memory pauseData = abi.encodeWithSelector(IntentAuth.pause.selector);
        timelock.schedule(address(hook), 0, pauseData, bytes32(0), bytes32(uint256(3)), 60);
        vm.stopBroadcast();

        vm.warp(block.timestamp + 61);

        vm.startBroadcast(deployer);
        timelock.execute(address(hook), 0, pauseData, bytes32(0), bytes32(uint256(3)));
        console2.log("Protocol paused:", hook.paused());

        bytes memory unpauseData = abi.encodeWithSelector(IntentAuth.unpause.selector);
        timelock.schedule(address(hook), 0, unpauseData, bytes32(0), bytes32(uint256(4)), 60);
        vm.stopBroadcast();

        vm.warp(block.timestamp + 61);

        vm.startBroadcast(deployer);
        timelock.execute(address(hook), 0, unpauseData, bytes32(0), bytes32(uint256(4)));
        console2.log("Protocol unpaused:", hook.paused());
        vm.stopBroadcast();

        // =============================================
        console2.log("=== E2E Walkthrough Complete ===");
        console2.log("Pools: native/USDC + tokenX/tokenY");
        console2.log("Paths covered:");
        console2.log("  - deploy + governance + oracle");
        console2.log("  - native swap + ERC20 swap");
        console2.log("  - full fill + partial fill");
        console2.log("  - user cancel + keeper cancel");
        console2.log("  - fee refund toggle");
        console2.log("  - timelock fee change");
        console2.log("  - timelock oracle config");
        console2.log("  - timelock fee claim");
        console2.log("  - pause + unpause");
        console2.log("  - swapper + filler + keeper rewards");
    }
}
