// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ScriptHelper} from "./ScriptHelper.sol";
import {ChronicleOracleAdapter, IChronicle, ISelfKisser} from "../src/oracle/ChronicleOracleAdapter.sol";

contract DeployChronicleOracleAdapterScript is ScriptHelper {
    ChronicleOracleAdapter public adapter;

    function run() public {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address selfKisser = _chronicleSelfKisserAddress();

        vm.startBroadcast(deployer);
        adapter = new ChronicleOracleAdapter(ISelfKisser(selfKisser), deployer);
        vm.stopBroadcast();
    }
}
