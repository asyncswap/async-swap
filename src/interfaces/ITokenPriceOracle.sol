// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title ITokenPriceOracle
/// @notice Returns the USD price for a given token address.
/// @dev V1.1 interface for token/USD fairness model.
///      Implementations should return prices normalized to 18 decimals (priceX18).
///      For native ETH, use address(0).
interface ITokenPriceOracle {
    /// @notice Get the current USD price for a token.
    /// @param token The token address (address(0) for native)
    /// @return priceX18 The token price in USD, scaled to 18 decimals (e.g., 3000e18 for $3000)
    /// @return updatedAt The timestamp when this price was last updated
    function getPrice(address token) external view returns (uint256 priceX18, uint256 updatedAt);
}
