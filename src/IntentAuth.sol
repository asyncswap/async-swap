// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IAsyncSwapOracle} from "./interfaces/IAsyncSwapOracle.sol";
import {ITokenPriceOracle} from "./interfaces/ITokenPriceOracle.sol";

contract IntentAuth {
    /// @notice The PoolManager contract address
    IPoolManager public immutable POOL_MANAGER;

    uint24 public minimumFee; // PPM{1} minimum fee ratio (denominator 1_000_000)
    bool public paused;
    address public protocolOwner;
    address public treasury;
    bool public feeRefundToggle;
    address public pendingOwner;
    mapping(Currency currency => uint256 amount) public accruedFees; // {tok} per currency
    mapping(Currency currency => uint256 amount) public accruedSurplus; // {tok} per currency
    mapping(PoolId poolId => uint24 fee) public poolFee; // PPM{1} per-pool fee ratio

    struct OracleConfig {
        IAsyncSwapOracle oracle;
        uint32 maxAge; // {s} maximum staleness for oracle price
        uint16 maxDeviationBps; // BPS{1} deviation tolerance before surplus capture
        uint16 userSurplusBps; // BPS{1} share of surplus returned to user
        uint16 fillerSurplusBps; // BPS{1} share of surplus awarded to filler
        uint16 protocolSurplusBps; // BPS{1} share of surplus retained by protocol
    }

    mapping(PoolId poolId => OracleConfig config) public oracleConfig;

    /// @notice Per-pool token price oracle for USD-value fairness (v1.1)
    ITokenPriceOracle public tokenPriceOracle;

    struct CancelCallback {
        Currency currency;
        address to;
        uint256 amount; // {tok} amount to refund
    }

    error NOT_PENDING_OWNER();
    error NO_FEES_ACCRUED();
    error NO_SURPLUS_ACCRUED();
    error TREASURY_NOT_SET();
    error PAUSED();

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event FeesClaimed(Currency indexed currency, address indexed to, uint256 amount);
    event SurplusClaimed(Currency indexed currency, address indexed to, uint256 amount);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event MinimumFeeUpdated(uint24 previousFee, uint24 newFee);
    event PoolFeeUpdated(PoolId indexed poolId, uint24 previousFee, uint24 newFee);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event FeeRefundToggleUpdated(bool previousValue, bool newValue);
    event OracleConfigUpdated(
        PoolId indexed poolId,
        address oracle,
        uint32 maxAge,
        uint16 maxDeviationBps,
        uint16 userSurplusBps,
        uint16 fillerSurplusBps,
        uint16 protocolSurplusBps
    );

    constructor(IPoolManager _poolManager, address _initialOwner, uint24 _minimumFee) {
        require(_minimumFee <= 1_000_000, "FEE TOO HIGH");
        POOL_MANAGER = _poolManager;
        protocolOwner = _initialOwner;
        minimumFee = _minimumFee;
        paused = true;
        emit OwnershipTransferred(address(0), _initialOwner);
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(protocolOwner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NOT_PENDING_OWNER();
        emit OwnershipTransferred(protocolOwner, msg.sender);
        protocolOwner = msg.sender;
        pendingOwner = address(0);
    }

    function setTreasury(address _treasury) external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setMinimumFee(uint24 _minimumFee) external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        require(_minimumFee <= 1_000_000, "FEE TOO HIGH");
        emit MinimumFeeUpdated(minimumFee, _minimumFee);
        minimumFee = _minimumFee;
    }

    function claimFees(Currency currency) external {
        if (treasury == address(0)) revert TREASURY_NOT_SET();

        uint256 amount = accruedFees[currency]; // {tok}
        if (amount == 0) revert NO_FEES_ACCRUED();

        delete accruedFees[currency];
        POOL_MANAGER.unlock(abi.encode(CancelCallback({currency: currency, to: treasury, amount: amount})));

        emit FeesClaimed(currency, treasury, amount);
    }

    function claimSurplus(Currency currency) external {
        if (treasury == address(0)) revert TREASURY_NOT_SET();

        uint256 amount = accruedSurplus[currency]; // {tok}
        if (amount == 0) revert NO_SURPLUS_ACCRUED();

        delete accruedSurplus[currency];
        POOL_MANAGER.unlock(abi.encode(CancelCallback({currency: currency, to: treasury, amount: amount})));

        emit SurplusClaimed(currency, treasury, amount);
    }

    /// @param _poolId The pool identifier
    /// @param _fee PPM{1} The new fee ratio (denominator 1_000_000)
    function setPoolFee(PoolId _poolId, uint24 _fee) external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        require(_fee >= minimumFee, "FEE BELOW MINIMUM");
        require(_fee <= 1_000_000, "FEE TOO HIGH"); // 1_000_000 PPM = 100%
        emit PoolFeeUpdated(_poolId, poolFee[_poolId], _fee);
        poolFee[_poolId] = _fee;
    }

    function setFeeRefundToggle(bool _enabled) external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        emit FeeRefundToggleUpdated(feeRefundToggle, _enabled);
        feeRefundToggle = _enabled;
    }

    /// @notice Set the global token price oracle for USD-value fairness (v1.1).
    function setTokenPriceOracle(ITokenPriceOracle _oracle) external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        tokenPriceOracle = _oracle;
    }

    /// @param _poolId The pool identifier
    /// @param _oracle The oracle contract
    /// @param _maxAge {s} Maximum staleness for oracle price
    /// @param _maxDeviationBps BPS{1} Deviation tolerance before surplus capture
    /// @param _userSurplusBps BPS{1} Share of surplus returned to user
    /// @param _fillerSurplusBps BPS{1} Share of surplus awarded to filler
    /// @param _protocolSurplusBps BPS{1} Share of surplus retained by protocol
    function setOracleConfig(
        PoolId _poolId,
        IAsyncSwapOracle _oracle,
        uint32 _maxAge,
        uint16 _maxDeviationBps,
        uint16 _userSurplusBps,
        uint16 _fillerSurplusBps,
        uint16 _protocolSurplusBps
    ) external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        require(
            uint256(_userSurplusBps) + uint256(_fillerSurplusBps) + uint256(_protocolSurplusBps) == 10_000, // BPS{1} must sum to 10_000 (100%)
            "INVALID_SPLIT"
        );
        oracleConfig[_poolId] = OracleConfig({
            oracle: _oracle,
            maxAge: _maxAge,
            maxDeviationBps: _maxDeviationBps,
            userSurplusBps: _userSurplusBps,
            fillerSurplusBps: _fillerSurplusBps,
            protocolSurplusBps: _protocolSurplusBps
        });
        emit OracleConfigUpdated(
            _poolId,
            address(_oracle),
            _maxAge,
            _maxDeviationBps,
            _userSurplusBps,
            _fillerSurplusBps,
            _protocolSurplusBps
        );
    }

    function pause() external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        paused = false;
        emit Unpaused(msg.sender);
    }
}
