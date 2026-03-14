// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/Test.sol";

contract ScriptHelper is Script {
    using stdJson for string;

    function _broadcastPath(string memory scriptName) internal view virtual returns (string memory) {
        string memory root = vm.projectRoot();
        return string.concat(
            root,
            "/broadcast/",
            scriptName,
            ".s.sol/",
            vm.toString(block.chainid),
            "/run-latest.json"
        );
    }

    function _readDeployedContractAddress(string memory scriptName, uint256 txIndex) internal view virtual returns (address) {
        string memory json = vm.readFile(_broadcastPath(scriptName));
        string memory key = string.concat(".transactions[", vm.toString(txIndex), "].contractAddress");
        return json.readAddress(key);
    }
}
