// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAsyncSwapOracle} from "../interfaces/IAsyncSwapOracle.sol";

interface IChronicle {
    /// @return value D18{tok1/tok0} The raw oracle price
    function read() external view returns (uint256 value);
    /// @return value D18{tok1/tok0} The raw oracle price
    /// @return age {s} The timestamp of the last update
    function readWithAge() external view returns (uint256 value, uint256 age);
}

interface ISelfKisser {
    function selfKiss(address oracle) external;
}

contract ChronicleOracleAdapter is IAsyncSwapOracle {
    struct PoolChronicleConfig {
        IChronicle chronicle;
        bool inverse;
        uint256 scaleNumerator; // {1} numerator of decimal-adjustment ratio
        uint256 scaleDenominator; // {1} denominator of decimal-adjustment ratio
    }

    address public owner;
    ISelfKisser public immutable selfKisser;
    mapping(PoolId poolId => PoolChronicleConfig config) public poolConfig;

    error NOT_OWNER();
    error INVALID_SCALE();
    error MISSING_POOL_ORACLE();
    error INVALID_PRICE();

    event PoolChronicleConfigured(
        PoolId indexed poolId, address oracle, bool inverse, uint256 scaleNumerator, uint256 scaleDenominator
    );

    constructor(ISelfKisser _selfKisser, address _owner) {
        selfKisser = _selfKisser;
        owner = _owner;
    }

    function setOwner(address newOwner) external {
        if (msg.sender != owner) revert NOT_OWNER();
        owner = newOwner;
    }

    function setPoolConfig(
        PoolId poolId,
        IChronicle chronicle,
        bool inverse,
        uint256 scaleNumerator,
        uint256 scaleDenominator,
        bool kiss
    ) external {
        if (msg.sender != owner) revert NOT_OWNER();
        if (scaleNumerator == 0 || scaleDenominator == 0) revert INVALID_SCALE();

        poolConfig[poolId] = PoolChronicleConfig({
            chronicle: chronicle, inverse: inverse, scaleNumerator: scaleNumerator, scaleDenominator: scaleDenominator
        });

        if (kiss) {
            selfKisser.selfKiss(address(chronicle));
        }

        emit PoolChronicleConfigured(poolId, address(chronicle), inverse, scaleNumerator, scaleDenominator);
    }

    function getQuoteSqrtPriceX96(PoolId poolId) external view returns (uint160 sqrtPriceX96, uint256 updatedAt) {
        PoolChronicleConfig memory cfg = poolConfig[poolId];
        if (address(cfg.chronicle) == address(0)) revert MISSING_POOL_ORACLE();

        (uint256 value, uint256 age) = cfg.chronicle.readWithAge(); // value: D18{tok1/tok0}, age: {s}
        updatedAt = age; // {s}

        // D18{tok1/tok0} = D18{tok1/tok0} * {1} / {1}
        uint256 priceX18 = Math.mulDiv(value, cfg.scaleNumerator, cfg.scaleDenominator);
        if (cfg.inverse) {
            if (priceX18 == 0) revert INVALID_PRICE();
            // D18{tok1/tok0} = D36 / D18{tok0/tok1}  (invert price, preserve D18 scaling)
            priceX18 = 1e36 / priceX18;
        }
        if (priceX18 == 0) revert INVALID_PRICE();

        // Q192{tok1/tok0} = D18{tok1/tok0} * 2^192 / 1e18
        uint256 ratioX192 = Math.mulDiv(priceX18, 2 ** 192, 1e18);
        // Q96{sqrt(tok1/tok0)} = sqrt(Q192{tok1/tok0})
        sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) revert INVALID_PRICE();
    }
}
