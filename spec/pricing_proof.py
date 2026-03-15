"""Z3 symbolic proof for AsyncSwap V1.1 pricing model.

Verifies that the token/USD cross-rate fairness computation
conserves value and bounds participant extraction.

Uses Z3 integer arithmetic for tractable solving.

Properties verified:
1. Surplus split conservation
2. Cross-rate truncation consistency
3. User share bounded by surplus
4. Filler total bounded by claim share
5. Protocol share non-negative
6. Truncation error bounded
7. Zero surplus on fair execution
"""

from z3 import Int, Solver, And, Or, Not, Implies, sat, unsat


def prove(name: str, preconditions, claim, verbose: bool = True):
    """Prove claim holds under preconditions by showing negation is unsat."""
    s = Solver()
    for p in preconditions:
        s.add(p)
    s.add(Not(claim))
    result = s.check()
    if result == unsat:
        if verbose:
            print(f"  PROVED: {name}")
        return True
    else:
        if verbose:
            print(f"  FAILED: {name}")
            if result == sat:
                print(f"  Counterexample: {s.model()}")
        return False


def verify_pricing_model():
    print("=== AsyncSwap V1.1 Pricing Model Z3 Proof ===\n")

    # Symbolic variables
    fillAmount = Int("fillAmount")
    claimShare = Int("claimShare")
    inputPrice = Int("inputPrice")
    outputPrice = Int("outputPrice")
    userBps = Int("userBps")
    fillerBps = Int("fillerBps")
    protocolBps = Int("protocolBps")

    # Derived: fair claim via cross-rate (integer division truncation)
    fairClaim = (fillAmount * outputPrice) / inputPrice

    # Preconditions
    pre = [
        fillAmount > 0,
        claimShare > 0,
        inputPrice > 0,
        outputPrice > 0,
        userBps >= 0,
        fillerBps >= 0,
        protocolBps >= 0,
        userBps + fillerBps + protocolBps == 10000,
        # Reasonable bounds
        fillAmount <= 10**24,
        claimShare <= 10**24,
        inputPrice <= 10**24,
        outputPrice <= 10**24,
    ]

    all_passed = True

    # =========================================================
    # Case 1: User disadvantaged (claimShare > fairClaim)
    # =========================================================
    print("Case 1: User disadvantaged (claimShare > fairClaim)")

    surplus = claimShare - fairClaim
    userShare = (surplus * userBps) / 10000
    fillerBonus = (surplus * fillerBps) / 10000
    protocolShare = surplus - userShare - fillerBonus
    fillerTotal = fairClaim + fillerBonus

    user_pre = pre + [claimShare > fairClaim]

    # 1. Surplus split conservation: userShare + fillerBonus + protocolShare == surplus
    all_passed &= prove(
        "surplus split conservation",
        user_pre,
        userShare + fillerBonus + protocolShare == surplus,
    )

    # 2. Protocol share non-negative
    all_passed &= prove(
        "protocol share non-negative",
        user_pre,
        protocolShare >= 0,
    )

    # 3. User share bounded by surplus
    all_passed &= prove(
        "user share bounded by surplus",
        user_pre,
        userShare <= surplus,
    )

    # 4. Filler bonus bounded by surplus
    all_passed &= prove(
        "filler bonus bounded by surplus",
        user_pre,
        fillerBonus <= surplus,
    )

    # 5. Filler total bounded by claim share
    all_passed &= prove(
        "filler total bounded by claim share",
        user_pre,
        fillerTotal <= claimShare,
    )

    # =========================================================
    # Case 2: Filler disadvantaged (fairClaim > claimShare)
    # =========================================================
    print("\nCase 2: Filler disadvantaged (fairClaim > claimShare)")

    filler_surplus = fairClaim - claimShare
    filler_pre = pre + [fairClaim > claimShare]

    # 6. Filler surplus is positive
    all_passed &= prove(
        "filler surplus is positive",
        filler_pre,
        filler_surplus > 0,
    )

    # =========================================================
    # Case 3: Fair execution
    # =========================================================
    print("\nCase 3: Fair execution (claimShare == fairClaim)")

    fair_pre = pre + [claimShare == fairClaim]

    # 7. Zero surplus
    all_passed &= prove(
        "zero surplus on fair execution",
        fair_pre,
        claimShare - fairClaim == 0,
    )

    # =========================================================
    # Cross-rate properties
    # =========================================================
    print("\nCross-rate properties")

    # 8. Truncation: fairClaim * inputPrice <= fillAmount * outputPrice
    all_passed &= prove(
        "cross-rate truncation (floor division)",
        pre,
        fairClaim * inputPrice <= fillAmount * outputPrice,
    )

    # 9. Truncation error bounded by inputPrice
    truncation_error = fillAmount * outputPrice - fairClaim * inputPrice
    all_passed &= prove(
        "truncation error bounded by inputPrice",
        pre,
        truncation_error < inputPrice,
    )

    # 10. Cross-rate is non-negative
    all_passed &= prove(
        "fair claim non-negative",
        pre,
        fairClaim >= 0,
    )

    # =========================================================
    print(f"\n=== Proof Complete: {'ALL PASSED' if all_passed else 'SOME FAILED'} ===")
    return all_passed


if __name__ == "__main__":
    verify_pricing_model()
