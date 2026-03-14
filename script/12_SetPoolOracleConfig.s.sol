// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {GovernanceAddressResolver} from "./GovernanceAddressResolver.sol";
import {AsyncSwap} from "../src/AsyncSwap.sol";
import {ChronicleOracleAdapter, IChronicle} from "../src/oracle/ChronicleOracleAdapter.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

contract SetPoolOracleConfigScript is GovernanceAddressResolver {
    function run() public {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address asyncSwap = _asyncSwapAddress();
        address adapterAddr = _deployedOracleAdapter();
        address chronicle = _chronicleOracleAddress();
        bool inverse = vm.envOr("ORACLE_INVERSE", false);
        uint256 scaleNumerator = vm.envOr("ORACLE_SCALE_NUMERATOR", uint256(1));
        uint256 scaleDenominator = vm.envOr("ORACLE_SCALE_DENOMINATOR", uint256(1));
        bool kiss = vm.envOr("ORACLE_SELF_KISS", true);

        PoolId poolId = PoolId.wrap(vm.envBytes32("POOL_ID"));
        uint32 maxAge = uint32(vm.envUint("ORACLE_MAX_AGE"));
        uint16 maxDeviationBps = uint16(vm.envUint("ORACLE_MAX_DEVIATION_BPS"));
        uint16 userSurplusBps = uint16(vm.envUint("USER_SURPLUS_BPS"));
        uint16 fillerSurplusBps = uint16(vm.envUint("FILLER_SURPLUS_BPS"));
        uint16 protocolSurplusBps = uint16(vm.envUint("PROTOCOL_SURPLUS_BPS"));

        vm.startBroadcast(deployer);
        ChronicleOracleAdapter(adapterAddr)
            .setPoolConfig(poolId, IChronicle(chronicle), inverse, scaleNumerator, scaleDenominator, kiss);
        AsyncSwap(asyncSwap)
            .setOracleConfig(
                poolId,
                ChronicleOracleAdapter(adapterAddr),
                maxAge,
                maxDeviationBps,
                userSurplusBps,
                fillerSurplusBps,
                protocolSurplusBps
            );
        vm.stopBroadcast();
    }
}
