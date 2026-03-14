// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ScriptHelper} from "./ScriptHelper.sol";

abstract contract GovernanceAddressResolver is ScriptHelper {
    function _timelockAddress() internal view returns (address) {
        return _deployedTimelock();
    }

    function _asyncSwapAddress() internal view returns (address) {
        return _deployedAsyncSwap();
    }

    function _asyncTokenAddress() internal view returns (address) {
        return _deployedAsyncToken();
    }

    function _governorAddress() internal view returns (address) {
        return _deployedGovernor();
    }

    function _acceptOwnershipCalldata() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("acceptOwnership()");
    }
}
