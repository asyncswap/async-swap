// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseAlgorithm } from "./BaseAlgorithm.sol";
import { IAlgorithm } from "@async-swap/interfaces/IAlgorithm.sol";
import { TransientStorage } from "@async-swap/utils/TransientStorage.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Algorithm 2: Buy and Sell Ordering by Jiasun Li.
/// @author Jiasun Li @ Async Labs
/// @notice This contract implements the Algorithm 2 for ordering transactions.
/// 1. lockBuy? := FALSE
/// 2. lockSell? := FALSE
/// 3. cumulatedVolume := 0
/// 4. beforeSwap: {
///   get(isNextTxBuyX)  ... {T or F}
///   if(lockBuy? == TRUE)
///   require(isNextTxBuyX? == TRUE)
///   else
///   if(lockSell? == TRUE)
///   require(isNextTxBuyX? == FALSE)
/// }
/// 5. tx
/// 6. afterSwap: {
///   if (cumulatedVolume * nextTxBuyXVolume > 0){
///      switch(nextTxBuyXVolume>0){
///         case(TRUE): lockBuy? := TRUE
///         case(FALSE): lockSell? := TRUE
///      }
///   }
///   cumulatedVolume += nextTxBuyXVolume
/// }
contract Algorithm2 is BaseAlgorithm, TransientStorage {

  using SafeCast for *;

  /// keccak256("algorithm2.isPrevBuy");
  bytes32 constant IS_PREV_BUY = 0x7e127a7bb2f4deeecd5997d5af18c995b303c3436532e9385868994ad2327421;
  /// keccak256("algorithm2.lockBuy");
  bytes32 constant LOCK_BUY = 0x69f5f7eb44562f4b9ec1f74ec5e0ed336b22f83917380c9a63672de30dade5dd;
  /// keccak256("algorithm2.lockSell");
  bytes32 constant LOCK_SELL = 0x052dd8f77e5de46dd4926f9e95c677f36f30fda8e014efe8c5d88724d6a4c9f8;
  /// keccak256("algorithm2.cummulativeAmount");
  bytes32 constant CUMULATIVE_AMOUNT = 0xd54a46fd16a77402970e6a9bd6bbd09b1f768d3161ee91442eaa078698d0f85a;

  constructor(address _hookAddress) BaseAlgorithm(_hookAddress) { }

  /// @inheritdoc IAlgorithm
  function name() external pure override returns (string memory) {
    return "Algorithm2";
  }

  /// @inheritdoc IAlgorithm
  function version() external pure override returns (string memory) {
    return "1.0.0";
  }

  /// Determines if the next transaction is a buy or a sell.
  /// @param zeroForOne true if the next transaction is a buy (zeroForOne = true) or a sell (zeroForOne = false).
  function isBuy(bool zeroForOne) public pure returns (bool) {
    return zeroForOne ? true : false;
  }

  /// @inheritdoc IAlgorithm
  function orderingRule(bool zeroForOne, uint256 amount) external virtual override onlyHook {
    bool isNextBuy;
    bool isPrevBuy;
    bool lockBuy;
    bool lockSell;
    int256 cummulativeAmount;

    isPrevBuy = tload(IS_PREV_BUY) != 0x00;
    lockBuy = tload(LOCK_BUY) != 0x00;
    lockSell = tload(LOCK_SELL) != 0x00;
    cummulativeAmount = uint256(tload(CUMULATIVE_AMOUNT)).toInt256();

    {
      // before excuting
      isNextBuy = isBuy(zeroForOne);
      if (lockBuy) {
        require(isNextBuy, "Buy order expected");
      } else {
        if (lockSell) {
          require(!isNextBuy, "Sell order expected");
        }
      }
    }

    {
      // after executing
      if (cummulativeAmount > 0) {
        tstore(LOCK_BUY, 0x00);
        tstore(LOCK_SELL, 0x0000000000000000000000000000000000000000000000000000000000000001);
      } else {
        tstore(LOCK_BUY, 0x0000000000000000000000000000000000000000000000000000000000000001);
        tstore(LOCK_SELL, 0x00);
      }

      tstore(
        IS_PREV_BUY,
        isNextBuy
          ? bytes32(0x0000000000000000000000000000000000000000000000000000000000000001)
          : bytes32(0x0000000000000000000000000000000000000000000000000000000000000000)
      );

      cummulativeAmount += zeroForOne ? int256(amount) : -int256(amount);
    }
  }

}
