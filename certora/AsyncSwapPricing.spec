/**
 * Certora CVL Specification for AsyncSwap V1.1 Pricing Model
 *
 * Verifies the actual Solidity implementation of previewUsdSurplusCapture()
 * against the pricing model properties proved symbolically by Z3.
 *
 * Properties verified:
 * 1. Surplus split conservation
 * 2. User share bounded by surplus
 * 3. Filler share bounded by claim share
 * 4. Protocol share non-negative (implied by conservation)
 * 5. No capture on fair execution
 * 6. User disadvantaged detection correctness
 * 7. Filler disadvantaged detection correctness
 * 8. Graceful degradation on missing oracle
 */

using AsyncSwap as hook;

methods {
    function previewUsdSurplusCapture(
        AsyncSwap.Order,
        bool,
        uint256
    ) external returns (AsyncSwap.SurplusPreview memory) envfree;

    function getBalanceIn(AsyncSwap.Order, bool) external returns (uint256) envfree;
    function getBalanceOut(AsyncSwap.Order, bool) external returns (uint256) envfree;
}

/**
 * Rule 1: Surplus split conservation
 * When surplus capture is active, userShare + fillerBonus + protocolShare == surplus
 * where fillerBonus = fillerShare - fairShare
 */
rule surplusSplitConservation(AsyncSwap.Order order, bool zeroForOne, uint256 fillAmount) {
    AsyncSwap.SurplusPreview preview = hook.previewUsdSurplusCapture(order, zeroForOne, fillAmount);

    // Only check when capture is active
    require preview.active;

    mathint surplus = preview.surplus;
    mathint userShare = preview.userShare;
    mathint fillerBonus = preview.fillerShare - preview.fairShare;
    mathint protocolShare = preview.protocolShare;

    assert userShare + fillerBonus + protocolShare == surplus,
        "surplus split must conserve total surplus";
}

/**
 * Rule 2: User share bounded by surplus
 */
rule userShareBoundedBySurplus(AsyncSwap.Order order, bool zeroForOne, uint256 fillAmount) {
    AsyncSwap.SurplusPreview preview = hook.previewUsdSurplusCapture(order, zeroForOne, fillAmount);

    require preview.active;

    assert preview.userShare <= preview.surplus,
        "user share must not exceed surplus";
}

/**
 * Rule 3: Filler total bounded by claim share
 * The filler should never receive more than the original quoted claim share
 */
rule fillerShareBoundedByClaimShare(AsyncSwap.Order order, bool zeroForOne, uint256 fillAmount) {
    AsyncSwap.SurplusPreview preview = hook.previewUsdSurplusCapture(order, zeroForOne, fillAmount);

    require preview.active;

    assert preview.fillerShare <= preview.claimShare,
        "filler total must not exceed original claim share";
}

/**
 * Rule 4: No capture on fair execution
 * When claimShare equals fairShare, surplus should be zero and capture inactive
 */
rule noCaptureOnFairExecution(AsyncSwap.Order order, bool zeroForOne, uint256 fillAmount) {
    AsyncSwap.SurplusPreview preview = hook.previewUsdSurplusCapture(order, zeroForOne, fillAmount);

    require preview.claimShare == preview.fairShare;
    require preview.fairShare > 0;

    assert !preview.active,
        "fair execution should not activate surplus capture";
    assert preview.surplus == 0,
        "fair execution should have zero surplus";
}

/**
 * Rule 5: Protocol share is non-negative
 */
rule protocolShareNonNegative(AsyncSwap.Order order, bool zeroForOne, uint256 fillAmount) {
    AsyncSwap.SurplusPreview preview = hook.previewUsdSurplusCapture(order, zeroForOne, fillAmount);

    // protocolShare is uint256 so it's always >= 0 by type,
    // but we verify the math doesn't underflow
    require preview.active;

    mathint computed = to_mathint(preview.surplus)
        - to_mathint(preview.userShare)
        - to_mathint(preview.fillerShare - preview.fairShare);

    assert computed >= 0,
        "protocol share computation must not underflow";
}

/**
 * Rule 6: Disadvantaged field consistency
 * If active and user disadvantaged, claimShare > fairShare
 * If filler disadvantaged, fairShare > claimShare
 */
rule disadvantagedFieldConsistency(AsyncSwap.Order order, bool zeroForOne, uint256 fillAmount) {
    AsyncSwap.SurplusPreview preview = hook.previewUsdSurplusCapture(order, zeroForOne, fillAmount);

    // User disadvantaged implies claimShare > fairShare
    assert (preview.active && preview.disadvantaged == AsyncSwap.Disadvantaged.User)
        => (preview.claimShare > preview.fairShare),
        "user disadvantaged requires claimShare > fairShare";

    // Filler disadvantaged implies fairShare > claimShare
    assert (preview.disadvantaged == AsyncSwap.Disadvantaged.Filler)
        => (preview.fairShare > preview.claimShare),
        "filler disadvantaged requires fairShare > claimShare";
}

/**
 * Rule 7: Graceful degradation
 * previewUsdSurplusCapture should never revert
 */
rule gracefulDegradation(AsyncSwap.Order order, bool zeroForOne, uint256 fillAmount) {
    AsyncSwap.SurplusPreview preview = hook.previewUsdSurplusCapture@withrevert(order, zeroForOne, fillAmount);

    assert !lastReverted,
        "previewUsdSurplusCapture must never revert";
}
