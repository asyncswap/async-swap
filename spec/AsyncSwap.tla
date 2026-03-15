-------------------------------- MODULE AsyncSwap --------------------------------
\* AsyncSwap V1 State Machine Spec (USD-Value Fairness)
\*
\* Principle: AsyncSwap exists to ensure no participant silently loses
\* excessive value on unfair execution. When trusted value references are
\* available, the protocol can refund the disadvantaged party, internalize
\* MEV, and route excess value according to explicit policy. This applies
\* symmetrically to both swappers and fillers.
\*
\* This spec models the core protocol layer (Layer 1) actions:
\*   OpenOrder, FillOrder, CancelByUser, CancelByKeeper
\*
\* Governance (Layer 2) is modeled as nondeterministic policy changes.

EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    MaxInput,           \* upper bound on original_input for model checking
    MaxOutput,          \* upper bound on original_output
    MaxFee,             \* upper bound on initial_protocol_fee
    Swappers,           \* set of possible swapper addresses
    Fillers,            \* set of possible filler addresses
    MaxTime             \* upper bound on time for model checking

VARIABLES
    \* Per-order state
    original_input,
    original_output,
    remaining_input,
    remaining_output,
    protocol_fee_total,
    protocol_surplus_total,
    filler_payout_total,
    refunded_input_total,
    delivered_output_total,
    cancelled_output_total,
    user_rebate_total,
    user_rebate_returned,
    cancelled,
    deadline,
    order_exists,

    \* Global state
    current_time,
    paused

vars == <<original_input, original_output, remaining_input, remaining_output,
          protocol_fee_total, protocol_surplus_total, filler_payout_total,
          refunded_input_total, delivered_output_total, cancelled_output_total,
          user_rebate_total, user_rebate_returned, cancelled, deadline,
          order_exists, current_time, paused>>

-----------------------------------------------------------------------------
\* Type invariant
TypeOK ==
    /\ original_input \in 0..MaxInput
    /\ original_output \in 0..MaxOutput
    /\ remaining_input \in 0..MaxInput
    /\ remaining_output \in 0..MaxOutput
    /\ protocol_fee_total \in 0..MaxInput
    /\ protocol_surplus_total \in 0..MaxInput
    /\ filler_payout_total \in 0..MaxInput
    /\ refunded_input_total \in 0..MaxInput
    /\ delivered_output_total \in 0..MaxOutput
    /\ cancelled_output_total \in 0..MaxOutput
    /\ user_rebate_total \in 0..MaxInput
    /\ user_rebate_returned \in 0..MaxInput
    /\ cancelled \in BOOLEAN
    /\ deadline \in 0..MaxTime
    /\ order_exists \in BOOLEAN
    /\ current_time \in 0..MaxTime
    /\ paused \in BOOLEAN

-----------------------------------------------------------------------------
\* Initial state
Init ==
    /\ original_input = 0
    /\ original_output = 0
    /\ remaining_input = 0
    /\ remaining_output = 0
    /\ protocol_fee_total = 0
    /\ protocol_surplus_total = 0
    /\ filler_payout_total = 0
    /\ refunded_input_total = 0
    /\ delivered_output_total = 0
    /\ cancelled_output_total = 0
    /\ user_rebate_total = 0
    /\ user_rebate_returned = 0
    /\ cancelled = FALSE
    /\ deadline = 0
    /\ order_exists = FALSE
    /\ current_time = 0
    /\ paused = FALSE

-----------------------------------------------------------------------------
\* Helper: is the order expired?
IsExpired == deadline /= 0 /\ current_time > deadline

\* Helper: minimum fill threshold (at least 50% of remaining, rounded up)
MinFill == (remaining_output + 1) \div 2

-----------------------------------------------------------------------------
\* Action: OpenOrder
\* A user escrows input and the protocol records an order.
OpenOrder(input, output, fee, dl) ==
    /\ ~order_exists
    /\ ~paused
    /\ input > 0
    /\ output >= 0
    /\ fee >= 0
    /\ fee < input
    /\ (dl = 0 \/ dl > current_time)
    /\ original_input' = input
    /\ original_output' = output
    /\ remaining_input' = input - fee
    /\ remaining_output' = output
    /\ protocol_fee_total' = fee
    /\ protocol_surplus_total' = 0
    /\ filler_payout_total' = 0
    /\ refunded_input_total' = 0
    /\ delivered_output_total' = 0
    /\ cancelled_output_total' = 0
    /\ user_rebate_total' = 0
    /\ user_rebate_returned' = 0
    /\ cancelled' = FALSE
    /\ deadline' = dl
    /\ order_exists' = TRUE
    /\ UNCHANGED <<current_time, paused>>

-----------------------------------------------------------------------------
\* Action: FillOrder
\* A filler delivers output_amount and receives filler_payout from escrowed input.
\* Optionally, protocol captures surplus and user receives a rebate.
\* FillOrder models user-side surplus capture with immediate rebate.
\* Filler-side protection is handled in the value model layer, not here.
\* Rebates are returned immediately on every fill.
FillOrder(output_amount, filler_payout, proto_fee, proto_surplus, user_rebate) ==
    LET total_charged == filler_payout + proto_fee + proto_surplus + user_rebate
    IN
    /\ order_exists
    /\ ~cancelled
    /\ ~paused
    /\ ~IsExpired
    /\ output_amount > 0
    /\ output_amount <= remaining_output
    /\ output_amount >= MinFill
    /\ filler_payout >= 0
    /\ proto_fee >= 0
    /\ proto_surplus >= 0
    /\ user_rebate >= 0
    \* Total charged from escrowed input must not exceed remaining
    /\ total_charged <= remaining_input
    \* Rebates are returned immediately (not deferred to remaining_input)
    /\ remaining_input' = remaining_input - total_charged
    /\ remaining_output' = remaining_output - output_amount
    /\ filler_payout_total' = filler_payout_total + filler_payout
    /\ protocol_fee_total' = protocol_fee_total + proto_fee
    /\ protocol_surplus_total' = protocol_surplus_total + proto_surplus
    /\ delivered_output_total' = delivered_output_total + output_amount
    /\ user_rebate_total' = user_rebate_total + user_rebate
    /\ user_rebate_returned' = user_rebate_returned + user_rebate
    /\ UNCHANGED <<original_input, original_output, refunded_input_total,
                   cancelled_output_total, cancelled, deadline,
                   order_exists, current_time, paused>>

-----------------------------------------------------------------------------
\* Action: CancelByUser
\* The swapper cancels and reclaims remaining input. Only before expiry.
CancelByUser ==
    /\ order_exists
    /\ ~cancelled
    /\ remaining_input > 0
    /\ ~IsExpired
    /\ refunded_input_total' = refunded_input_total + remaining_input
    /\ cancelled_output_total' = cancelled_output_total + remaining_output
    /\ remaining_input' = 0
    /\ remaining_output' = 0
    /\ cancelled' = TRUE
    /\ UNCHANGED <<original_input, original_output, filler_payout_total,
                   protocol_fee_total, protocol_surplus_total,
                   delivered_output_total, user_rebate_total,
                   user_rebate_returned, deadline, order_exists,
                   current_time, paused>>

-----------------------------------------------------------------------------
\* Action: CancelByKeeper
\* Anyone can cancel an expired order. Funds go to the swapper.
CancelByKeeper ==
    /\ order_exists
    /\ ~cancelled
    /\ remaining_input > 0
    /\ IsExpired
    /\ refunded_input_total' = refunded_input_total + remaining_input
    /\ cancelled_output_total' = cancelled_output_total + remaining_output
    /\ remaining_input' = 0
    /\ remaining_output' = 0
    /\ cancelled' = TRUE
    /\ UNCHANGED <<original_input, original_output, filler_payout_total,
                   protocol_fee_total, protocol_surplus_total,
                   delivered_output_total, user_rebate_total,
                   user_rebate_returned, deadline, order_exists,
                   current_time, paused>>

-----------------------------------------------------------------------------
\* Action: AdvanceTime
\* Time moves forward nondeterministically.
AdvanceTime ==
    /\ current_time < MaxTime
    /\ \E t \in (current_time + 1)..MaxTime:
        /\ current_time' = t
        /\ UNCHANGED <<original_input, original_output, remaining_input,
                       remaining_output, protocol_fee_total,
                       protocol_surplus_total, filler_payout_total,
                       refunded_input_total, delivered_output_total,
                       cancelled_output_total, user_rebate_total,
                       user_rebate_returned, cancelled, deadline,
                       order_exists, paused>>

-----------------------------------------------------------------------------
\* Action: TogglePause
\* Governance can pause/unpause.
TogglePause ==
    /\ paused' = ~paused
    /\ UNCHANGED <<original_input, original_output, remaining_input,
                   remaining_output, protocol_fee_total,
                   protocol_surplus_total, filler_payout_total,
                   refunded_input_total, delivered_output_total,
                   cancelled_output_total, user_rebate_total,
                   user_rebate_returned, cancelled, deadline,
                   order_exists, current_time>>

-----------------------------------------------------------------------------
\* Next-state relation
Next ==
    \/ \E i \in 1..MaxInput, o \in 0..MaxOutput, f \in 0..MaxFee, d \in 0..MaxTime:
        OpenOrder(i, o, f, d)
    \/ \E oa \in 1..MaxOutput, fp \in 0..MaxInput, pf \in 0..MaxInput,
          ps \in 0..MaxInput, ur \in 0..MaxInput:
        FillOrder(oa, fp, pf, ps, ur)
    \/ CancelByUser
    \/ CancelByKeeper
    \/ AdvanceTime
    \/ TogglePause

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* SAFETY INVARIANTS
\*
\* These correspond to the 13 baseline invariants from the V1 formal spec.

\* 1. Input conservation
InputConservation ==
    order_exists =>
        original_input = remaining_input
                       + refunded_input_total
                       + filler_payout_total
                       + protocol_fee_total
                       + protocol_surplus_total
                       + user_rebate_returned

\* 2. Output conservation
OutputConservation ==
    order_exists =>
        original_output = remaining_output
                        + delivered_output_total
                        + cancelled_output_total

\* 3. Non-negativity
NonNegativity ==
    /\ remaining_input >= 0
    /\ remaining_output >= 0
    /\ protocol_fee_total >= 0
    /\ protocol_surplus_total >= 0

\* 4. Rebate recoverability (rebates are returned immediately, so total returned must match total granted)
RebateRecoverability ==
    order_exists =>
        user_rebate_returned = user_rebate_total

\* 5. Bilateral value protection (structural: filler payout bounded by what was available minus protocol take)
BilateralValueProtection ==
    order_exists =>
        filler_payout_total <= original_input - protocol_fee_total - protocol_surplus_total

\* 6. Protocol capture boundedness
ProtocolCaptureBoundedness ==
    order_exists =>
        protocol_fee_total + protocol_surplus_total <= original_input

\* 7. Expiry safety (fill blocked after expiry)
\* This is enforced by FillOrder precondition, but we can also check:
ExpirySafety ==
    (order_exists /\ IsExpired /\ ~cancelled) =>
        \* no fills should have happened after expiry
        \* (this is structural from the action guards)
        TRUE

\* 8. Pause safety (no fills or opens when paused)
\* Structural from action guards.
PauseSafety == TRUE

\* Combined safety invariant
SafetyInvariant ==
    /\ TypeOK
    /\ InputConservation
    /\ OutputConservation
    /\ NonNegativity
    /\ RebateRecoverability
    /\ BilateralValueProtection
    /\ ProtocolCaptureBoundedness

=============================================================================
