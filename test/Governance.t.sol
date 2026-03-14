// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {IntentAuth} from "../src/IntentAuth.sol";
import {AsyncToken} from "../src/governance/AsyncToken.sol";
import {AsyncGovernor} from "../src/governance/AsyncGovernor.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract AsyncTokenTest is Test {
    AsyncToken token;
    address minter = makeAddr("minter");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new AsyncToken(minter);
    }

    function test_constructor_setsMinter() public view {
        assertEq(token.minter(), minter);
        assertEq(token.name(), "AsyncSwap");
        assertEq(token.symbol(), "ASYNC");
    }

    function test_mint_byMinter() public {
        vm.prank(minter);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_mint_nonMinter_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AsyncToken.NOT_MINTER.selector);
        token.mint(alice, 1);
    }

    function test_mint_aboveCap_reverts() public {
        vm.startPrank(minter);
        token.mint(alice, token.MAX_SUPPLY());
        vm.expectRevert(AsyncToken.MAX_SUPPLY_EXCEEDED.selector);
        token.mint(alice, 1);
        vm.stopPrank();
    }

    function test_setMinter_updatesMinter() public {
        vm.prank(minter);
        token.setMinter(bob);
        assertEq(token.minter(), bob);
    }

    function test_setMinter_nonMinter_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AsyncToken.NOT_MINTER.selector);
        token.setMinter(bob);
    }

    function test_votes_checkpointing() public {
        vm.startPrank(minter);
        token.mint(alice, 100e18);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.prank(alice);
        token.delegate(alice);

        vm.roll(block.number + 1);
        assertEq(token.getVotes(alice), 100e18);
    }
}

contract AsyncGovernorTest is Test {
    AsyncToken token;
    TimelockController timelock;
    AsyncGovernor governor;
    address admin = makeAddr("admin");

    function setUp() public {
        token = new AsyncToken(address(this));
        address[] memory proposers = new address[](1);
        proposers[0] = address(0); // placeholder, grant later
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open executor role
        timelock = new TimelockController(1 days, proposers, executors, admin);
        governor = new AsyncGovernor(token, timelock, 1, 10, 100e18, 4);

        vm.startPrank(admin);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        vm.stopPrank();
    }

    function test_governor_config() public view {
        assertEq(governor.votingDelay(), 1);
        assertEq(governor.votingPeriod(), 10);
        assertEq(governor.proposalThreshold(), 100e18);
        assertEq(governor.name(), "AsyncSwap Governor");
    }

    function test_governor_quorum() public {
        token.mint(address(this), 1_000e18);
        vm.roll(block.number + 1);
        token.delegate(address(this));
        vm.roll(block.number + 1);
        assertEq(governor.quorum(block.number - 1), 40e18);
    }
}

contract AsyncGovernanceExecutionTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AsyncSwap hook;
    AsyncToken token;
    TimelockController timelock;
    AsyncGovernor governor;
    PoolKey poolKey;
    PoolId poolId;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    address voter = makeAddr("voter");
    address treasury = makeAddr("treasury");

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
            tickSpacing: 240,
            hooks: IHooks(hookAddr)
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        token = new AsyncToken(address(this));
        address[] memory proposers = new address[](1);
        proposers[0] = address(0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(1 days, proposers, executors, address(this));
        governor = new AsyncGovernor(token, timelock, 1, 10, 100e18, 4);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));

        hook.transferOwnership(address(timelock));
        vm.prank(address(timelock));
        hook.acceptOwnership();

        token.mint(voter, 1_000_000e18);
        vm.roll(block.number + 1);
        vm.prank(voter);
        token.delegate(voter);
        vm.roll(block.number + 2);
    }

    function test_governance_can_setTreasury_onAsyncSwap() public {
        address[] memory targets = new address[](1);
        targets[0] = address(hook);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(IntentAuth.setTreasury.selector, treasury);
        string memory description = "set treasury";

        vm.prank(voter);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + governor.votingDelay() + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + governor.votingPeriod() + 1);
        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + 1 days + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(hook.treasury(), treasury);
        assertEq(hook.protocolOwner(), address(timelock));
    }

    function test_governance_can_setPoolFee_onAsyncSwap() public {
        address[] memory targets = new address[](1);
        targets[0] = address(hook);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(IntentAuth.setPoolFee.selector, poolId, uint24(20_000));
        string memory description = "set pool fee";

        vm.prank(voter);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + governor.votingDelay() + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + governor.votingPeriod() + 1);
        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + 1 days + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(hook.poolFee(poolId), 20_000);
    }

    function test_governance_can_toggle_feeRefund_onAsyncSwap() public {
        address[] memory targets = new address[](1);
        targets[0] = address(hook);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(IntentAuth.setFeeRefundToggle.selector, true);
        string memory description = "enable fee refund toggle";

        vm.prank(voter);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + governor.votingDelay() + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + governor.votingPeriod() + 1);
        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + 1 days + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertTrue(hook.feeRefundToggle());
    }
}
