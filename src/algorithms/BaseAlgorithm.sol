// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAlgorithm } from "@async-swap/interfaces/IAlgorithm.sol";

contract BaseAlgorithm is IAlgorithm {

  /// @notice The address of the hook that will call this algorithm.
  address public immutable HOOKADDRESS;

  /// @notice Constructor to set the hook address.
  /// @param _hookAddress The address of the hook that will call this algorithm.
  constructor(address _hookAddress) {
    HOOKADDRESS = _hookAddress;
  }

  /// @notice Modifier to restrict access to the hook address.
  /// @dev only hook contract can call
  modifier onlyHook() {
    _checkCallerIsHookContract();
    _;
  }

  function _checkCallerIsHookContract() internal view {
    require(msg.sender == HOOKADDRESS, "Only hook can call this function");
  }

  /// @inheritdoc IAlgorithm
  function name() external pure virtual returns (string memory) {
    return "BaseAlgorithm";
  }

  /// @inheritdoc IAlgorithm
  function version() external pure virtual returns (string memory) {
    return "1.0.0";
  }

  /// @inheritdoc IAlgorithm
  function orderingRule(bool zeroForOne, uint256 amount) external virtual {
    zeroForOne;
    amount;
    revert("BaseAlgorithm: orderingRule not implemented");
  }

}
