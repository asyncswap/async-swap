// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";

contract AsyncSwap layout at 1000 {

    /// @notice The PoolManager contract address
    IPoolManager public poolManager;

    /// @notice Error if caller is not poolmanager address 
    error CallerNotPoolManager();

    /// @notice Initialize PoolManager storage variable
    constructor(IPoolManager _pm) {
        poolManager = _pm;
    }

    /// @notice Only PoolManager contract allowed as msg.sender
    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), CallerNotPoolManager());
        _;
    }
}
