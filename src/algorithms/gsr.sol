// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseAlgorithm } from "./BaseAlgorithm.sol";
import { IAlgorithm } from "@async-swap/interfaces/IAlgorithm.sol";

/// @title Greedy Sequencing Rule (GSR) Ordering Contract
/// @author Meek Msaki @ Async Labs
/// @notice This contract implements the Greedy Sequencing Rule (GSR) for ordering transactions.
/// The GSR algorithm is a transaction ordering rule that follows the following principles:
/// 1. Start with any trade. Incase of vhGSR, the first trade is the smallest trade.
/// 2. If the price is above status-quo (overbought), pick a sell.
/// 3. Otherwise, pick a buy.
/// 4. Repeat 2-3 until all choices are exhausted.
/// @custom:clvr https://arxiv.org/abs/2408.02634
/// @custom:gdr https://arxiv.org/pdf/2209.15569
contract GSR is BaseAlgorithm {

  constructor(address _hookAddress) BaseAlgorithm(_hookAddress) { }

  /// @inheritdoc IAlgorithm
  function name() external pure override returns (string memory) {
    return "GSR";
  }

  /// @inheritdoc IAlgorithm
  function version() external pure override returns (string memory) {
    return "1.0.0";
  }

  /// @inheritdoc IAlgorithm
  function orderingRule(bool zeroForOne, uint256 amount) external override onlyHook {
    /// TODO: Implement the GSR algorithm logic here.
  }

}
