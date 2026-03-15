// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IAsyncSwapOracle} from "./interfaces/IAsyncSwapOracle.sol";

contract IntentAuth {
    /// @notice The PoolManager contract address
    IPoolManager public immutable POOL_MANAGER;

    uint24 public minimumFee = 1_2000;
    bool public paused;
    address public protocolOwner;
    address public treasury;
    bool public feeRefundToggle;
    address public pendingOwner;
    mapping(Currency currency => uint256 amount) public accruedFees;
    mapping(Currency currency => uint256 amount) public accruedSurplus;
    mapping(PoolId poolId => uint24 fee) public poolFee;

    struct OracleConfig {
        IAsyncSwapOracle oracle;
        uint32 maxAge;
        uint16 maxDeviationBps;
        uint16 userSurplusBps;
        uint16 fillerSurplusBps;
        uint16 protocolSurplusBps;
    }

    mapping(PoolId poolId => OracleConfig config) public oracleConfig;

    struct CancelCallback {
        Currency currency;
        address to;
        uint256 amount;
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

    constructor(IPoolManager _poolManager, address _initialOwner) {
        POOL_MANAGER = _poolManager;
        protocolOwner = _initialOwner;
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
        emit MinimumFeeUpdated(minimumFee, _minimumFee);
        minimumFee = _minimumFee;
    }

    function claimFees(Currency currency) external {
        if (treasury == address(0)) revert TREASURY_NOT_SET();

        uint256 amount = accruedFees[currency];
        if (amount == 0) revert NO_FEES_ACCRUED();

        delete accruedFees[currency];
        POOL_MANAGER.unlock(abi.encode(CancelCallback({currency: currency, to: treasury, amount: amount})));

        emit FeesClaimed(currency, treasury, amount);
    }

    function claimSurplus(Currency currency) external {
        if (treasury == address(0)) revert TREASURY_NOT_SET();

        uint256 amount = accruedSurplus[currency];
        if (amount == 0) revert NO_SURPLUS_ACCRUED();

        delete accruedSurplus[currency];
        POOL_MANAGER.unlock(abi.encode(CancelCallback({currency: currency, to: treasury, amount: amount})));

        emit SurplusClaimed(currency, treasury, amount);
    }

    function setPoolFee(PoolId _poolId, uint24 _fee) external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        require(_fee >= minimumFee, "FEE BELOW MINIMUM");
        require(_fee <= 1_000_000, "FEE TOO HIGH");
        emit PoolFeeUpdated(_poolId, poolFee[_poolId], _fee);
        poolFee[_poolId] = _fee;
    }

    function setFeeRefundToggle(bool _enabled) external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        emit FeeRefundToggleUpdated(feeRefundToggle, _enabled);
        feeRefundToggle = _enabled;
    }

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
            uint256(_userSurplusBps) + uint256(_fillerSurplusBps) + uint256(_protocolSurplusBps) == 10_000,
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
