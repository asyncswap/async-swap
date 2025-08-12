// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseAlgorithm } from "./BaseAlgorithm.sol";
import { IAlgorithm } from "@async-swap/interfaces/IAlgorithm.sol";

/// @title Volume Heuristic Greedy Sequencing Rule (VGSR).
/// @author Async Labs
/// @notice This contract implements the Volume Heuristic Greedy Sequencing Rule (VGSR) for ordering transactions.
/// 1. On top of the GSR method (namely, alternate between buy and sell).
/// 1. The algorithm prioritizes selecting small transactions before bigger ones.
contract VGSR is BaseAlgorithm {

  constructor(address _hookAddress) BaseAlgorithm(_hookAddress) { }

  /// @inheritdoc IAlgorithm
  function name() external pure override returns (string memory) {
    return "VGSR";
  }

  /// @inheritdoc IAlgorithm
  function version() external pure override returns (string memory) {
    return "1.0.0";
  }

  /// @inheritdoc IAlgorithm
  function orderingRule(bool zeroForOne, uint256 amount) external override onlyHook {
    /// TODO: Implement the VGSR algorithm logic here.
  }

}
