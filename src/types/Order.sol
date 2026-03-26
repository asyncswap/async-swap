// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @param poolId The pool this order belongs to
/// @param swapper The creator of the order
/// @param tick The tick (price point) at which to execute the order
struct Order {
    PoolId poolId;
    address swapper;
    int24 tick;
}

library OrderLibrary {
    function toId(Order memory order) external pure returns (bytes32 orderId) {
        return keccak256(abi.encode(order));
    }
}
