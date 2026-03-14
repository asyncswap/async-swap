// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ChronicleOracleAdapter, IChronicle, ISelfKisser} from "../src/oracle/ChronicleOracleAdapter.sol";

contract ChronicleOracleAdapterTest is Test {
    ChronicleOracleAdapter adapter;
    MockChronicle chronicle;
    MockSelfKisser selfKisser;
    PoolId constant POOL_ID = PoolId.wrap(bytes32(uint256(1)));
    address owner = makeAddr("owner");

    function setUp() public {
        chronicle = new MockChronicle();
        selfKisser = new MockSelfKisser();
        adapter = new ChronicleOracleAdapter(ISelfKisser(address(selfKisser)), owner);
    }

    function test_setPoolConfig_nonOwner_reverts() public {
        vm.prank(makeAddr("mallory"));
        vm.expectRevert(ChronicleOracleAdapter.NOT_OWNER.selector);
        adapter.setPoolConfig(POOL_ID, IChronicle(address(chronicle)), false, 1e6, 1e18, false);
    }

    function test_setPoolConfig_kisses_oracle() public {
        vm.prank(owner);
        adapter.setPoolConfig(POOL_ID, IChronicle(address(chronicle)), false, 1e6, 1e18, true);
        assertEq(selfKisser.lastOracle(), address(chronicle));
    }

    function test_getQuoteSqrtPrice_reads_price_and_age() public {
        chronicle.setQuote(3000e18, 1234);

        vm.prank(owner);
        adapter.setPoolConfig(POOL_ID, IChronicle(address(chronicle)), false, 1e6, 1e18, false);

        (uint160 sqrtPriceX96, uint256 updatedAt) = adapter.getQuoteSqrtPriceX96(POOL_ID);
        assertEq(updatedAt, 1234);
        assertTrue(sqrtPriceX96 != 0);
    }

    function test_getQuoteSqrtPrice_missingConfig_reverts() public {
        vm.expectRevert(ChronicleOracleAdapter.MISSING_POOL_ORACLE.selector);
        adapter.getQuoteSqrtPriceX96(POOL_ID);
    }

    function test_getQuoteSqrtPrice_inverse_path() public {
        chronicle.setQuote(3000e18, 1234);

        vm.prank(owner);
        adapter.setPoolConfig(POOL_ID, IChronicle(address(chronicle)), true, 1e6, 1e18, false);

        (uint160 sqrtPriceX96,) = adapter.getQuoteSqrtPriceX96(POOL_ID);
        assertTrue(sqrtPriceX96 != 0);
    }
}

contract MockChronicle is IChronicle {
    uint256 internal value;
    uint256 internal age;

    function setQuote(uint256 _value, uint256 _age) external {
        value = _value;
        age = _age;
    }

    function read() external view returns (uint256) {
        return value;
    }

    function readWithAge() external view returns (uint256, uint256) {
        return (value, age);
    }
}

contract MockSelfKisser is ISelfKisser {
    address internal kissed;

    function selfKiss(address oracle) external {
        kissed = oracle;
    }

    function lastOracle() external view returns (address) {
        return kissed;
    }
}
