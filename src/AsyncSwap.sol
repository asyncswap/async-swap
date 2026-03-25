// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {AsyncRouter} from "./AsyncRouter.sol";
import {CurrencySettler} from "./libraries/CurrencySettler.sol";
import {IntentAuth} from "./IntentAuth.sol";
import {AsyncToken} from "./governance/AsyncToken.sol";

/// @title AsyncSwap
/// @notice An intent-based async swap hook built on Uniswap V4.
/// @dev V1 Principle: AsyncSwap exists to ensure users do not silently lose value on bad quotes.
///      When trusted value references are available, the protocol can refund users, internalize MEV,
///      and route excess value according to explicit policy.
///
///      Oracle and surplus policy is read live from governance config at execution time.
///      This is intentional — fairness is judged by the policy in force when value is actually exchanged.
contract AsyncSwap is IntentAuth, IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    /// @notice The Router — deployed by constructor, immutable
    AsyncRouter public immutable router;

    /// @notice The governance token used for participant rewards
    AsyncToken public rewardToken;

    /// @notice One-time reward amount for each role (1 token = 1e18)
    uint256 public constant PARTICIPANT_REWARD = 1e18; // D18{ASYNC} 1 ASYNC token

    /// @notice Minimum refund amount required for keeper reward eligibility
    uint256 public constant MIN_KEEPER_REWARD_SIZE = 1e15; // {tok} 0.001 token (assumes D18 ERC-20)

    /// @notice Tracks whether an address has already claimed their swapper reward
    mapping(address => bool) public hasSwapReward;
    /// @notice Tracks whether an address has already claimed their filler reward
    mapping(address => bool) public hasFillerReward;
    /// @notice Tracks whether an address has already claimed their keeper reward
    mapping(address => bool) public hasKeeperReward;

    /// Stores pools registered on this hook
    mapping(PoolId poolId => PoolKey key) public pools;
    /// Swap orders for input token
    /// balancesIn initialized by swapper and mutated by filler
    mapping(bytes32 orderId => mapping(bool zeroForOne => uint256 amountGiven)) public balancesIn; // {tok}
    /// Swap orders for output token
    /// balancesOut initialized by swapper and mutated by filler
    mapping(bytes32 orderId => mapping(bool zeroForOne => uint256 amountTaken)) public balancesOut; // {tok}
    /// Remaining fee quota for on-fill mode, per order and direction
    mapping(bytes32 orderId => mapping(bool zeroForOne => uint256 amount)) public feeRemaining; // {tok}
    /// Order deadline per orderId and direction (0 = no expiry)
    mapping(bytes32 orderId => mapping(bool zeroForOne => uint256 deadline)) public orderDeadline; // {s}

    /// @param poolId The pool this order belongs to
    /// @param swapper The creator of the order
    /// @param tick The tick (price point) at which to execute the order
    struct Order {
        PoolId poolId;
        address swapper;
        int24 tick;
    }

    /// @notice Which participant is disadvantaged by the quoted execution.
    /// @dev V1 uses pair-relative oracle (sqrtPriceX96) for detection.
    ///      The target architecture is token/USD valuation in a common numeraire,
    ///      where both user and filler loss are measurable in the same value unit.
    ///      User-side surplus capture is enforced on-chain.
    ///      Filler-side detection is informational in V1.
    enum Disadvantaged {
        None,
        User,
        Filler
    }

    struct SurplusPreview {
        bool active;
        Disadvantaged disadvantaged;
        uint256 claimShare; // {tok} input claimed by filler (before surplus adjustment)
        uint256 fairShare; // {tok} fair input value at oracle price
        uint256 surplus; // {tok} |claimShare - fairShare|
        uint256 userShare; // {tok} surplus refunded to user
        uint256 fillerShare; // {tok} input awarded to filler (fairShare + fillerBonus)
        uint256 protocolShare; // {tok} surplus retained by protocol
        uint256 deviationBps; // BPS{1} surplus / fairShare (or surplus / claimShare for filler-side)
        uint160 oracleSqrtPriceX96; // Q96{sqrt(tok1/tok0)} oracle reference price
        uint256 oracleUpdatedAt; // {s} oracle price timestamp
    }

    /// @notice Emitted when an async swap order is created
    event Swap(bytes32 orderId, Order order);

    /// @notice Emitted when a filler partially or fully fills an order
    event Fill(bytes32 orderId, address filler, uint256 fillAmount, uint256 inputShare);

    /// @notice Emitted when a swapper cancels an unfilled order and reclaims input tokens
    event Cancel(bytes32 orderId, address swapper, uint256 amountReturned);

    /// @notice Error if caller is not poolmanager address
    error CALLER_NOT_POOL_MANAGER();

    /// @notice Error for method not implemented
    error HOOK_NOT_IN_USE();

    /// @notice Just become a filler instead
    error PROVIDE_LIQUIDITY_BY_SOLVING();

    /// @notice Fill amount is below the minimum (50% of remaining)
    error FILL_AMOUNT_TOO_SMALL();

    /// @notice No remaining output to fill
    error ORDER_ALREADY_FILLED();

    /// @notice Fill amount exceeds remaining output
    error FILL_EXCEEDS_REMAINING();

    /// @notice ERC-20 transfer from filler to swapper failed
    error OUTPUT_TRANSFER_FAILED();

    /// @notice Output token did not deliver the exact requested amount
    error INSUFFICIENT_OUTPUT_RECEIVED();

    /// @notice Native output fill used the wrong msg.value or ERC20 fill sent stray ETH
    error INVALID_NATIVE_OUTPUT_VALUE();

    /// @notice Only the order's swapper can cancel
    error NOT_ORDER_OWNER();

    /// @notice No remaining input to cancel
    error NOTHING_TO_CANCEL();

    /// @notice Order poolId does not match the active pool key
    error POOL_MISMATCH();

    /// @notice Pool id is not registered on this hook
    error UNKNOWN_POOL();

    /// @notice Only PoolManager can call unlockCallback
    error CALLER_NOT_POOL_MANAGER_CALLBACK();

    /// @notice Order has expired and can no longer be filled
    error ORDER_EXPIRED();

    /// @notice Initialize PoolManager storage variable and deploy the router
    constructor(IPoolManager _pm, address _initialOwner, uint24 _minimumFee)
        IntentAuth(_pm, _initialOwner, _minimumFee)
    {
        router = new AsyncRouter(_pm, address(this));
    }

    /// @notice Set the governance token used for participant rewards. Only callable by protocolOwner.
    function setRewardToken(AsyncToken _token) external {
        require(msg.sender == protocolOwner, "NOT OWNER");
        rewardToken = _token;
    }

    /// @notice Mint a one-time reward to a participant if they haven't already received one.
    function _tryMintReward(address recipient, mapping(address => bool) storage claimed) internal {
        if (address(rewardToken) == address(0)) return;
        if (claimed[recipient]) return;
        claimed[recipient] = true;
        try rewardToken.mint(recipient, PARTICIPANT_REWARD) {} catch {}
    }

    /// @notice Only PoolManager contract allowed as msg.sender
    modifier onlyPoolManager() {
        _onlyPoolManager();
        _;
    }

    /// @notice internal function requires caller is PoolManager
    function _onlyPoolManager() internal view {
        require(msg.sender == address(POOL_MANAGER), CALLER_NOT_POOL_MANAGER());
    }

    /// @notice Validates the deployed hook
    /// @param _this A Hook contract
    function validateHookAddress(IHooks _this) internal pure {
        Hooks.validateHookPermissions(_this, getHookPermissions());
    }

    /// @notice Returns activated hook permissions
    /// @return permissions active hook perssions
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // true
            afterInitialize: true, // true
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // prevent liquidity adds
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // true
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // true
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    //////////////////////////
    ///////// Core ///////////
    //////////////////////////

    /// @notice The balance of remaining tokens to be filled by solver
    /// @param order The swap order
    /// @return amountGiven {tok} The amount supplied by swapper (net input + feeRemaining)
    function getBalanceIn(Order memory order, bool zeroForOne) public view returns (uint256 amountGiven) {
        bytes32 orderId = keccak256(abi.encode(order));
        amountGiven = balancesIn[orderId][zeroForOne] + feeRemaining[orderId][zeroForOne];
    }

    /// @notice The balance of remaining tokens to be taken by swapper
    /// @param order The order submitted by swapper
    /// @return amountRemaining {tok} The remaining amount output tokens to be solved by filler
    function getBalanceOut(Order memory order, bool zeroForOne) public view returns (uint256 amountRemaining) {
        bytes32 orderId = keccak256(abi.encode(order));
        amountRemaining = balancesOut[orderId][zeroForOne];
    }

    /// @notice Swap entry point — users call this directly.
    ///         Delegates to the router which calls PM.swap() so beforeSwap fires.
    /// @param key The pool to swap on
    /// @param zeroForOne Swap direction
    /// @param amountIn {tok} Exact input amount
    /// @param tick The order's price tick
    /// @param minAmountOut {tok} Minimum output (slippage protection)
    /// @param deadline {s} Order expiry timestamp (0 = no expiry)
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        int24 tick,
        uint256 minAmountOut,
        uint256 deadline
    ) external payable {
        if (paused) revert PAUSED();
        require(amountIn > 0, "ZERO_AMOUNT");
        if (deadline != 0 && deadline <= block.timestamp) revert ORDER_EXPIRED();

        router.executeSwap{value: msg.value}(
            AsyncRouter.SwapData({
                user: msg.sender,
                key: key,
                tick: tick,
                amountIn: amountIn,
                zeroForOne: zeroForOne,
                minAmountOut: minAmountOut,
                value: msg.value
            })
        );

        // Store deadline for this order (after router call so orderId exists)
        Order memory order = Order({poolId: key.toId(), swapper: msg.sender, tick: tick});
        bytes32 orderId = keccak256(abi.encode(order));
        if (deadline > 0) {
            // Only update if no existing deadline or new deadline is earlier
            uint256 existing = orderDeadline[orderId][zeroForOne];
            if (existing == 0 || deadline < existing) {
                orderDeadline[orderId][zeroForOne] = deadline;
            }
        }

        // One-time swapper reward
        _tryMintReward(msg.sender, hasSwapReward);
    }

    //////////////////////////
    ///// HOOK ACTIVATED /////
    //////////////////////////

    /// @inheritdoc IHooks
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        /// @dev only owner of this hook is allowed to initialize pools
        require(sender == protocolOwner, "NOT HOOK OWNER");
        require(address(key.hooks) == address(this));
        /// @dev pool must use dynamic fee flag for governance-controlled fees
        require(key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, "USE DYNAMIC FEE");

        return this.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterInitialize(address sender, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        /// @dev only owner of this contract can modify pools initialization
        require(sender == protocolOwner);
        /// @dev store poolId and set initial fee
        pools[key.toId()] = key;
        poolFee[key.toId()] = minimumFee;

        return this.afterInitialize.selector;
    }

    /// @notice Compute the output amount given net input, price tick, and swap direction.
    ///         Rounds down so the user gets slightly less (protocol never loses).
    /// @param amountInAfterFee {tok} Net input after fee deduction
    /// @param tick The order's price tick
    /// @param zeroForOne Swap direction
    /// @return amountOut {tok} The computed output amount
    function _computeAmountOut(uint256 amountInAfterFee, int24 tick, bool zeroForOne)
        internal
        pure
        returns (uint256 amountOut)
    {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick); // Q96{sqrt(tok1/tok0)}
        if (zeroForOne) {
            // Selling token0 for token1: amountOut = amountInAfterFee * price
            // {tok1} = {tok0} * Q96{sqrt(tok1/tok0)} / Q96 * Q96{sqrt(tok1/tok0)} / Q96
            amountOut = FullMath.mulDiv(
                FullMath.mulDiv(amountInAfterFee, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96
            );
        } else {
            // Selling token1 for token0: amountOut = amountInAfterFee / price
            // {tok0} = {tok1} * Q96 / Q96{sqrt(tok1/tok0)} * Q96 / Q96{sqrt(tok1/tok0)}
            amountOut = FullMath.mulDiv(
                FullMath.mulDiv(amountInAfterFee, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice
            );
        }
    }

    /// @notice Compute the input required for a target output at a fixed tick.
    ///         Uses rounding up so the fair share is conservative.
    /// @param amountOut {tok} Target output amount
    /// @return amountIn {tok} Required input amount (rounded up)
    function _computeInputForOutput(uint256 amountOut, int24 tick, bool zeroForOne)
        internal
        pure
        returns (uint256 amountIn)
    {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick); // Q96{sqrt(tok1/tok0)}
        return _computeInputForOutputAtSqrtPrice(amountOut, sqrtPrice, zeroForOne);
    }

    /// @param amountOut {tok} Target output amount
    /// @param sqrtPrice Q96{sqrt(tok1/tok0)} The square-root price
    /// @return amountIn {tok} Required input amount (rounded up)
    function _computeInputForOutputAtSqrtPrice(uint256 amountOut, uint160 sqrtPrice, bool zeroForOne)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (zeroForOne) {
            // {tok0} = {tok1} * Q96 / Q96{sqrt(tok1/tok0)} * Q96 / Q96{sqrt(tok1/tok0)}
            amountIn = FullMath.mulDivRoundingUp(
                FullMath.mulDivRoundingUp(amountOut, FixedPoint96.Q96, sqrtPrice), FixedPoint96.Q96, sqrtPrice
            );
        } else {
            // {tok1} = {tok0} * Q96{sqrt(tok1/tok0)} / Q96 * Q96{sqrt(tok1/tok0)} / Q96
            amountIn = FullMath.mulDivRoundingUp(
                FullMath.mulDivRoundingUp(amountOut, sqrtPrice, FixedPoint96.Q96), sqrtPrice, FixedPoint96.Q96
            );
        }
    }

    /// @notice Preview oracle-based surplus capture for a proposed fill.
    /// @dev V1 design decision: oracle and surplus policy is read live from governance config
    ///      at execution time, not snapshotted per order. This means governance changes can
    ///      affect fills on already-open orders. This is intentional — fairness is judged by
    ///      the policy in force when value is actually exchanged, not when the order was created.
    /// @param order The order being filled
    /// @param zeroForOne The swap direction
    /// @param fillAmount {tok} The amount of output tokens to fill
    function previewSurplusCapture(Order memory order, bool zeroForOne, uint256 fillAmount)
        public
        view
        returns (SurplusPreview memory preview)
    {
        PoolKey memory key = pools[order.poolId];
        if (address(key.hooks) != address(this)) return preview;

        uint256 remainingOut = balancesOut[keccak256(abi.encode(order))][zeroForOne]; // {tok}
        uint256 remainingIn = balancesIn[keccak256(abi.encode(order))][zeroForOne]; // {tok}
        if (remainingOut == 0 || fillAmount == 0 || fillAmount > remainingOut) return preview;

        OracleConfig memory cfg = oracleConfig[order.poolId];
        if (address(cfg.oracle) == address(0)) return preview;

        uint160 oracleSqrtPriceX96; // Q96{sqrt(tok1/tok0)}
        uint256 updatedAt; // {s}
        try cfg.oracle.getQuoteSqrtPriceX96(order.poolId) returns (uint160 sqrtPrice, uint256 age) {
            oracleSqrtPriceX96 = sqrtPrice;
            updatedAt = age;
        } catch {
            // Oracle read failed — degrade gracefully, skip surplus capture
            return preview;
        }
        if (cfg.maxAge > 0 && block.timestamp > updatedAt + cfg.maxAge) {
            preview.oracleSqrtPriceX96 = oracleSqrtPriceX96;
            preview.oracleUpdatedAt = updatedAt;
            return preview;
        }

        // {tok_in} = {tok_out} * {tok_in} / {tok_out}
        uint256 inputShare = FullMath.mulDiv(fillAmount, remainingIn, remainingOut);
        uint256 claimShare = inputShare; // {tok_in}
        uint256 remainingFee = feeRemaining[keccak256(abi.encode(order))][zeroForOne]; // {tok_in}

        uint256 fairShare = _computeInputForOutputAtSqrtPrice(fillAmount, oracleSqrtPriceX96, zeroForOne); // {tok_in}
        if (remainingFee > 0) {
            // Use the order's own fee proportion, not the live poolFee,
            // so oracle fairness and fee accounting use the same basis.
            // {tok_in} = {tok_out} * {tok_in} / {tok_out}
            uint256 fairFee = fillAmount == remainingOut  // {tok_in}
                ? remainingFee
                : FullMath.mulDivRoundingUp(fillAmount, remainingFee, remainingOut);
            fairShare = fairFee >= fairShare ? 0 : fairShare - fairFee; // {tok_in}
        }
        if (claimShare == fairShare) {
            // Perfectly fair execution
            preview.claimShare = claimShare;
            preview.fairShare = fairShare;
            preview.disadvantaged = Disadvantaged.None;
            preview.oracleSqrtPriceX96 = oracleSqrtPriceX96;
            preview.oracleUpdatedAt = updatedAt;
            return preview;
        }

        if (claimShare > fairShare) {
            // User is disadvantaged — overpaying relative to oracle
            uint256 surplus = claimShare - fairShare; // {tok_in}
            // BPS{1} = {tok_in} * 10_000 / {tok_in}
            uint256 deviationBps = fairShare == 0 ? type(uint256).max : FullMath.mulDiv(surplus, 10_000, fairShare);

            if (cfg.maxDeviationBps > 0 && deviationBps <= cfg.maxDeviationBps) {
                // Within tolerance — no capture
                preview.claimShare = claimShare;
                preview.fairShare = fairShare;
                preview.surplus = surplus;
                preview.deviationBps = deviationBps;
                preview.disadvantaged = Disadvantaged.User;
                preview.oracleSqrtPriceX96 = oracleSqrtPriceX96;
                preview.oracleUpdatedAt = updatedAt;
                return preview;
            }

            // {tok_in} = {tok_in} * BPS{1} / 10_000
            uint256 userShare = FullMath.mulDiv(surplus, cfg.userSurplusBps, 10_000);
            // {tok_in} = {tok_in} * BPS{1} / 10_000
            uint256 fillerBonus = FullMath.mulDiv(surplus, cfg.fillerSurplusBps, 10_000);

            preview.active = true;
            preview.disadvantaged = Disadvantaged.User;
            preview.claimShare = claimShare;
            preview.fairShare = fairShare;
            preview.surplus = surplus;
            preview.userShare = userShare;
            preview.fillerShare = fairShare + fillerBonus; // {tok_in}
            preview.protocolShare = surplus - userShare - fillerBonus; // {tok_in}
            preview.deviationBps = deviationBps;
            preview.oracleSqrtPriceX96 = oracleSqrtPriceX96;
            preview.oracleUpdatedAt = updatedAt;
        } else {
            // Filler is disadvantaged — user quote is too favorable
            // Detection only — filler protection is informational in V1.
            uint256 surplus = fairShare - claimShare; // {tok_in}

            preview.active = false;
            preview.disadvantaged = Disadvantaged.Filler;
            preview.claimShare = claimShare;
            preview.fairShare = fairShare;
            preview.surplus = surplus;
            preview.fillerShare = claimShare;
            preview.deviationBps = claimShare == 0 ? type(uint256).max : FullMath.mulDiv(surplus, 10_000, claimShare);
            preview.oracleSqrtPriceX96 = oracleSqrtPriceX96;
            preview.oracleUpdatedAt = updatedAt;
        }
    }

    /// @notice Preview USD-value surplus capture using per-token USD price feeds.
    /// @dev V1.1: uses ITokenPriceOracle to value both sides of a fill in USD,
    ///      then detects surplus and computes the split. Falls back to the v1.0
    ///      sqrtPriceX96 path if tokenPriceOracle is not configured.
    /// @param order The order being filled
    /// @param zeroForOne The swap direction
    /// @param fillAmount {tok} The amount of output tokens to fill
    function previewUsdSurplusCapture(Order memory order, bool zeroForOne, uint256 fillAmount)
        public
        view
        returns (SurplusPreview memory preview)
    {
        if (address(tokenPriceOracle) == address(0)) {
            return previewSurplusCapture(order, zeroForOne, fillAmount);
        }

        PoolKey memory key = pools[order.poolId];
        if (address(key.hooks) != address(this)) return preview;

        bytes32 orderId = keccak256(abi.encode(order));
        uint256 remainingOut = balancesOut[orderId][zeroForOne]; // {tok}
        uint256 remainingIn = balancesIn[orderId][zeroForOne]; // {tok}
        if (remainingOut == 0 || fillAmount == 0 || fillAmount > remainingOut) return preview;

        OracleConfig memory cfg = oracleConfig[order.poolId];

        address inputToken = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        address outputToken = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);

        uint256 inputPriceX18; // D18{UoA/tok}
        uint256 outputPriceX18; // D18{UoA/tok}
        uint256 inputUpdatedAt; // {s}
        uint256 outputUpdatedAt; // {s}

        try tokenPriceOracle.getPrice(inputToken) returns (uint256 p, uint256 u) {
            inputPriceX18 = p;
            inputUpdatedAt = u;
        } catch {
            return previewSurplusCapture(order, zeroForOne, fillAmount);
        }

        try tokenPriceOracle.getPrice(outputToken) returns (uint256 p, uint256 u) {
            outputPriceX18 = p;
            outputUpdatedAt = u;
        } catch {
            return previewSurplusCapture(order, zeroForOne, fillAmount);
        }

        if (inputPriceX18 == 0 || outputPriceX18 == 0) {
            return previewSurplusCapture(order, zeroForOne, fillAmount);
        }

        uint256 minUpdatedAt = inputUpdatedAt < outputUpdatedAt ? inputUpdatedAt : outputUpdatedAt; // {s}
        if (cfg.maxAge > 0 && block.timestamp > minUpdatedAt + cfg.maxAge) {
            return preview;
        }

        // {tok_in} = {tok_out} * {tok_in} / {tok_out}
        uint256 inputShare = FullMath.mulDiv(fillAmount, remainingIn, remainingOut); // {tok_in}
        uint256 claimShare = inputShare; // {tok_in}

        // Compute fairClaimShare: how much input is worth the output at oracle prices
        // {tok_in} = {tok_out} * D18{UoA/tok_out} / D18{UoA/tok_in}
        uint256 fairClaimShare =
            outputPriceX18 == 0 ? claimShare : FullMath.mulDiv(fillAmount, outputPriceX18, inputPriceX18); // {tok_in}

        // Deduct proportional fee so fairClaimShare is net-of-fee, matching claimShare basis
        uint256 remainingFee = feeRemaining[orderId][zeroForOne]; // {tok_in}
        if (remainingFee > 0) {
            // {tok_in} = {tok_out} * {tok_in} / {tok_out}
            uint256 fairFee = fillAmount == remainingOut
                ? remainingFee
                : FullMath.mulDivRoundingUp(fillAmount, remainingFee, remainingOut); // {tok_in}
            fairClaimShare = fairFee >= fairClaimShare ? 0 : fairClaimShare - fairFee; // {tok_in}
        }

        if (claimShare == fairClaimShare) {
            preview.claimShare = claimShare;
            preview.fairShare = fairClaimShare;
            preview.disadvantaged = Disadvantaged.None;
            return preview;
        }

        if (claimShare > fairClaimShare) {
            // User disadvantaged
            uint256 surplus = claimShare - fairClaimShare; // {tok_in}
            // BPS{1} = {tok_in} * 10_000 / {tok_in}
            uint256 deviationBps =
                fairClaimShare == 0 ? type(uint256).max : FullMath.mulDiv(surplus, 10_000, fairClaimShare); // BPS{1}

            if (cfg.maxDeviationBps > 0 && deviationBps <= cfg.maxDeviationBps) {
                preview.claimShare = claimShare;
                preview.fairShare = fairClaimShare;
                preview.surplus = surplus;
                preview.deviationBps = deviationBps;
                preview.disadvantaged = Disadvantaged.User;
                return preview;
            }

            // {tok_in} = {tok_in} * BPS{1} / 10_000
            uint256 userShare = FullMath.mulDiv(surplus, cfg.userSurplusBps, 10_000); // {tok_in}
            // {tok_in} = {tok_in} * BPS{1} / 10_000
            uint256 fillerBonus = FullMath.mulDiv(surplus, cfg.fillerSurplusBps, 10_000); // {tok_in}

            preview.active = true;
            preview.disadvantaged = Disadvantaged.User;
            preview.claimShare = claimShare;
            preview.fairShare = fairClaimShare;
            preview.surplus = surplus;
            preview.userShare = userShare;
            preview.fillerShare = fairClaimShare + fillerBonus; // {tok_in}
            preview.protocolShare = surplus - userShare - fillerBonus; // {tok_in}
            preview.deviationBps = deviationBps;
        } else {
            // Filler disadvantaged
            uint256 surplus = fairClaimShare - claimShare; // {tok_in}

            preview.active = false;
            preview.disadvantaged = Disadvantaged.Filler;
            preview.claimShare = claimShare;
            preview.fairShare = fairClaimShare;
            preview.surplus = surplus;
            preview.fillerShare = claimShare;
            preview.deviationBps = claimShare == 0 ? type(uint256).max : FullMath.mulDiv(surplus, 10_000, claimShare);
        }
    }

    /// @inheritdoc IHooks
    /// @notice Only exact-input swaps (amountSpecified < 0) are supported.
    ///         For "exact output" intents, the router should pre-compute the required
    ///         input amount and submit as exact-input.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender != address(router)) revert("UNTRUSTED ROUTER");

        // Only exact-input supported. Exact-output intents should be converted
        // to exact-input by the router before calling swap().
        require(params.amountSpecified < 0, "EXACT INPUT ONLY");

        uint256 amountIn = uint256(-params.amountSpecified); // {tok}

        _processOrder(hookData, key, params.zeroForOne, amountIn);

        // deltaSpecified = -amountSpecified (positive) cancels the AMM swap.
        // For exact-input, specified currency = input currency.
        // Hook's +delta from this return is offset by the -delta from take()/mint().
        // Net hook delta = 0. Router's swapDelta = -hookDelta, so router settles amountIn.
        // Return the pool's dynamic fee with override flag set
        uint24 fee = poolFee[key.toId()] | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(-params.amountSpecified), 0), fee);
    }

    /// @notice Decode hookData, compute output, check slippage, take claim tokens, record order
    /// @param amountIn {tok} Exact input amount (gross, before fee)
    function _processOrder(bytes calldata hookData, PoolKey calldata key, bool zeroForOne, uint256 amountIn) internal {
        (Order memory order, uint256 minAmountOut) = abi.decode(hookData, (Order, uint256)); // minAmountOut: {tok}

        if (PoolId.unwrap(order.poolId) != PoolId.unwrap(key.toId())) revert POOL_MISMATCH();

        // Take fee from input using the pool's dynamic fee (round up so protocol keeps more)
        uint24 fee = poolFee[key.toId()]; // PPM{1}
        // {tok} = {tok} * PPM{1} / 1_000_000
        uint256 feeAmount = FullMath.mulDivRoundingUp(amountIn, fee, 1_000_000);
        uint256 netInput = amountIn - feeAmount; // {tok}

        // Compute output from net input after fee (round down so user gets less)
        uint256 amountOut = _computeAmountOut(netInput, order.tick, zeroForOne); // {tok}

        // Slippage protection: user's minimum acceptable output
        require(amountOut >= minAmountOut, "SLIPPAGE");

        // Take full input (including fee) as claim tokens from PoolManager
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        inputCurrency.take(POOL_MANAGER, address(this), amountIn, true);

        // Record order for filler to settle later.
        // Upfront mode exposes only net input to fillers.
        // On-fill mode exposes gross input and accrues fees as fills happen.
        bytes32 orderId = keccak256(abi.encode(order));
        if (!feeRefundToggle) {
            accruedFees[inputCurrency] += feeAmount;
            balancesIn[orderId][zeroForOne] += netInput;
        } else {
            feeRemaining[orderId][zeroForOne] += feeAmount;
            balancesIn[orderId][zeroForOne] += netInput;
        }
        balancesOut[orderId][zeroForOne] += amountOut;

        emit Swap(orderId, order);
    }

    /// @notice Deliver output tokens from filler to swapper and require exact delivery.
    /// @param amount {tok} The exact amount to deliver
    /// @param value {tok} Native ETH value (0 for ERC-20)
    function _deliverOutput(address filler, Currency outputCurrency, address recipient, uint256 amount, uint256 value)
        internal
    {
        if (outputCurrency.isAddressZero()) {
            if (value != amount) revert INVALID_NATIVE_OUTPUT_VALUE();
            outputCurrency.transfer(recipient, amount);
            return;
        }

        if (value != 0) revert INVALID_NATIVE_OUTPUT_VALUE();

        address token = Currency.unwrap(outputCurrency);
        uint256 beforeBal = IERC20Minimal(token).balanceOf(recipient);
        (bool callSuccess, bytes memory returndata) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, filler, recipient, amount));
        if (!callSuccess || (returndata.length > 0 && !abi.decode(returndata, (bool)))) {
            revert OUTPUT_TRANSFER_FAILED();
        }
        uint256 received = IERC20Minimal(token).balanceOf(recipient) - beforeBal;
        if (received != amount) revert INSUFFICIENT_OUTPUT_RECEIVED();
    }

    //////////////////////////
    //////// Filler //////////
    //////////////////////////

    /// @notice Fill an order by providing output tokens to the swapper in exchange for input claim tokens.
    ///         Permissionless — anyone can fill. Each fill must cover at least 50% of the remaining
    ///         output, ensuring the order converges in O(log n) fills.
    /// @param order The order to fill (must match an existing orderId with remaining balance)
    /// @param zeroForOne The swap direction of the original order
    /// @param fillAmount {tok} The amount of output tokens the filler is providing
    function fill(Order memory order, bool zeroForOne, uint256 fillAmount) external payable {
        _fill(order, zeroForOne, fillAmount, msg.sender, msg.value);
    }

    /// @notice Batch fill multiple orders in a single transaction.
    ///         Enables coincidence-of-wants settlement where a solver matches
    ///         opposite-direction orders and settles them together.
    ///         Native output fills are not supported in batch mode.
    /// @param orders Array of orders to fill
    /// @param zeroForOnes Array of swap directions for each order
    /// @param fillAmounts Array of output amounts the filler is providing for each order
    function batchFill(Order[] calldata orders, bool[] calldata zeroForOnes, uint256[] calldata fillAmounts) external {
        uint256 length = orders.length;
        require(length == zeroForOnes.length && length == fillAmounts.length, "LENGTH_MISMATCH");

        for (uint256 i; i < length; ++i) {
            _fill(orders[i], zeroForOnes[i], fillAmounts[i], msg.sender, 0);
        }
    }

    /// @notice Internal fill logic shared by fill() and batchFill()
    function _fill(Order memory order, bool zeroForOne, uint256 fillAmount, address filler, uint256 value) internal {
        if (paused) revert PAUSED();
        bytes32 orderId = keccak256(abi.encode(order));

        // Check expiry
        uint256 deadline = orderDeadline[orderId][zeroForOne]; // {s}
        if (deadline != 0 && block.timestamp > deadline) revert ORDER_EXPIRED();

        PoolKey memory key = pools[order.poolId];
        if (address(key.hooks) != address(this)) revert UNKNOWN_POOL();

        uint256 remainingOut = balancesOut[orderId][zeroForOne]; // {tok}
        if (remainingOut == 0) revert ORDER_ALREADY_FILLED();
        if (fillAmount > remainingOut) revert FILL_EXCEEDS_REMAINING();

        // Minimum fill: at least 50% of remaining (rounds up so the last fill can close it out)
        uint256 minFill = (remainingOut + 1) / 2; // {tok}
        if (fillAmount < minFill) revert FILL_AMOUNT_TOO_SMALL();

        // Compute proportional input share: fillAmount * balancesIn / balancesOut (round down)
        uint256 remainingIn = balancesIn[orderId][zeroForOne]; // {tok}
        // {tok_in} = {tok_out} * {tok_in} / {tok_out}
        uint256 inputShare = FullMath.mulDiv(fillAmount, remainingIn, remainingOut);

        // Preview oracle-based surplus capture before mutating state.
        // Prefer USD-value path (v1.1) if tokenPriceOracle is configured; fall back to sqrtPriceX96 (v1.0).
        SurplusPreview memory preview = previewUsdSurplusCapture(order, zeroForOne, fillAmount);

        // Update state before external calls
        balancesOut[orderId][zeroForOne] = remainingOut - fillAmount;
        balancesIn[orderId][zeroForOne] = remainingIn - inputShare;

        // Determine currencies from the stored pool key
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        uint256 claimShare = inputShare; // {tok_in}
        uint256 remainingFee = feeRemaining[orderId][zeroForOne]; // {tok_in}
        if (remainingFee > 0) {
            // {tok_in} = {tok_in} * {tok_in} / {tok_in}
            uint256 feeShare = fillAmount == remainingOut  // {tok_in}
                ? remainingFee
                : FullMath.mulDivRoundingUp(inputShare, remainingFee, remainingIn);

            feeRemaining[orderId][zeroForOne] = remainingFee - feeShare;
            accruedFees[inputCurrency] += feeShare;
        }

        // Oracle-based surplus capture.
        // User rebate is returned immediately on every fill to match the verified spec.
        if (preview.active) {
            claimShare = preview.fillerShare;
            accruedSurplus[inputCurrency] += preview.protocolShare;
            POOL_MANAGER.transfer(order.swapper, inputCurrency.toId(), preview.userShare);
        }

        // Transfer output tokens from filler directly to swapper
        _deliverOutput(filler, outputCurrency, order.swapper, fillAmount, value);

        // Transfer proportional input claim tokens (ERC-6909) from hook to filler
        POOL_MANAGER.transfer(filler, inputCurrency.toId(), claimShare);

        emit Fill(orderId, filler, fillAmount, claimShare);

        // One-time filler reward
        _tryMintReward(filler, hasFillerReward);
    }

    //////////////////////////
    /////// Cancel ////////////
    //////////////////////////

    /// @notice Cancel an order and reclaim all remaining input tokens.
    ///         Before expiry: only the swapper can cancel.
    ///         After expiry: anyone can cancel (keeper), and the keeper gets a one-time reward.
    ///         Tokens always go back to the swapper.
    /// @param order The order to cancel
    /// @param zeroForOne The swap direction of the original order
    function cancelOrder(Order memory order, bool zeroForOne) external {
        bytes32 orderId = keccak256(abi.encode(order));
        uint256 deadline = orderDeadline[orderId][zeroForOne]; // {s}
        bool expired = deadline != 0 && block.timestamp > deadline;

        // Before expiry: only swapper can cancel. After expiry: anyone can cancel.
        if (!expired && msg.sender != order.swapper) revert NOT_ORDER_OWNER();

        PoolKey memory key = pools[order.poolId];
        if (address(key.hooks) != address(this)) revert UNKNOWN_POOL();

        uint256 remainingIn = balancesIn[orderId][zeroForOne]; // {tok}
        if (remainingIn == 0) revert NOTHING_TO_CANCEL();

        uint256 remainingFee = feeRemaining[orderId][zeroForOne]; // {tok}
        uint256 refundAmount = remainingIn + remainingFee; // {tok}

        // Clear storage (gas refund)
        // In on-fill mode, feeRemaining is forgiven — unfilled swaps do not pay fees.
        delete balancesIn[orderId][zeroForOne];
        delete balancesOut[orderId][zeroForOne];
        delete feeRemaining[orderId][zeroForOne];
        delete orderDeadline[orderId][zeroForOne];

        // Unlock PoolManager to burn claim tokens and send real ERC-20 to swapper
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;

        POOL_MANAGER.unlock(
            abi.encode(CancelCallback({currency: inputCurrency, to: order.swapper, amount: refundAmount}))
        );

        emit Cancel(orderId, order.swapper, refundAmount);

        // One-time keeper reward for cleaning up expired orders (minimum size required)
        if (expired && msg.sender != order.swapper && refundAmount >= MIN_KEEPER_REWARD_SIZE) {
            _tryMintReward(msg.sender, hasKeeperReward);
        }
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), CALLER_NOT_POOL_MANAGER_CALLBACK());

        CancelCallback memory cb = abi.decode(data, (CancelCallback));

        // Burn the hook's claim tokens (creates +delta)
        POOL_MANAGER.burn(address(this), cb.currency.toId(), cb.amount);
        // Take real ERC-20 from PoolManager to swapper (creates -delta, netting to zero)
        POOL_MANAGER.take(cb.currency, cb.to, cb.amount);

        return "";
    }

    ///////////////////////////
    ///// HOOK NOT IN USE /////
    ///////////////////////////

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HOOK_NOT_IN_USE();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert PROVIDE_LIQUIDITY_BY_SOLVING();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HOOK_NOT_IN_USE();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HOOK_NOT_IN_USE();
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, int128)
    {
        revert HOOK_NOT_IN_USE();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HOOK_NOT_IN_USE();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HOOK_NOT_IN_USE();
    }
}
