// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseAlgorithm } from "./BaseAlgorithm.sol";
import { IAlgorithm } from "@async-swap/interfaces/IAlgorithm.sol";

/// @title Gini Mean Difference (GMD).
/// @author Meek Msaki @ Async Labs
/// @notice This contract implements the GMD algorithm for ordering transactions.
/// @custom:gpt-description https://chatgpt.com/share/68558f98-3fd0-8003-8cec-d54a575fc688
contract GMD is BaseAlgorithm {

  constructor(address _hookAddress) BaseAlgorithm(_hookAddress) { }

  /// @inheritdoc IAlgorithm
  function name() external pure override returns (string memory) {
    return "GMD";
  }

  /// @inheritdoc IAlgorithm
  function version() external pure override returns (string memory) {
    return "1.0.0";
  }

  /// @inheritdoc IAlgorithm
  function orderingRule(bool zeroForOne, uint256 amount) external override onlyHook {
    /// TODO: Implement the GMD algorithm logic here.
  }

}
