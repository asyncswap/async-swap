// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title AsyncToken
/// @notice ERC20 governance token for the AsyncSwap protocol.
///         - Governance: vote on protocol parameters (fees, tick bounds, oracle settings)
///         - Fee sharing: holders earn protocol fee revenue
///         - Filler staking: fillers stake for priority access to fill orders
/// @dev Extends ERC20Votes for on-chain voting power tracking with checkpoints,
///      and ERC20Permit for gasless approvals via EIP-2612.
contract AsyncToken is ERC20, ERC20Permit, ERC20Votes {
    /// @notice Maximum total supply: 100 million tokens (18 decimals)
    uint256 public constant MAX_SUPPLY = 100_000_000e18; // D18{ASYNC} 100M tokens

    /// @notice Supply cap exceeded
    error MAX_SUPPLY_EXCEEDED();

    /// @notice Only the minter can mint new tokens
    error NOT_MINTER();

    /// @notice The address authorized to mint tokens
    address public minter;

    /// @notice Emitted when the minter is changed
    event MinterChanged(address indexed previousMinter, address indexed newMinter);

    /// @param _minter The initial minter address (e.g., the protocol owner or a vesting contract)
    constructor(address _minter) ERC20("AsyncSwap", "ASYNC") ERC20Permit("AsyncSwap") {
        minter = _minter;
        emit MinterChanged(address(0), _minter);
    }

    /// @notice Mint new tokens. Only callable by the minter. Respects MAX_SUPPLY cap.
    /// @param to The recipient of the minted tokens
    /// @param amount D18{ASYNC} The amount to mint
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NOT_MINTER();
        if (totalSupply() + amount > MAX_SUPPLY) revert MAX_SUPPLY_EXCEEDED();
        _mint(to, amount);
    }

    /// @notice Transfer the minter role to a new address. Only callable by the current minter.
    /// @param newMinter The new minter address
    function setMinter(address newMinter) external {
        if (msg.sender != minter) revert NOT_MINTER();
        emit MinterChanged(minter, newMinter);
        minter = newMinter;
    }

    // ========================================
    // Required overrides for ERC20 + ERC20Votes
    // ========================================

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
