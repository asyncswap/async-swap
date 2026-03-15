# AsyncSwap TLA+ Specification

This directory contains a TLA+ formal specification for the AsyncSwap V1 state machine.

## Files

- `AsyncSwap.tla` — the TLA+ specification
- `AsyncSwap.cfg` — the TLC model checker configuration

## What it models

Core protocol actions (Layer 1):
- `OpenOrder` — user escrows input, protocol records order
- `FillOrder` — filler delivers output, receives input claims, optional surplus capture
- `CancelByUser` — swapper reclaims remaining input before expiry
- `CancelByKeeper` — anyone reclaims remaining input after expiry
- `AdvanceTime` — time moves forward nondeterministically
- `TogglePause` — governance pauses/unpauses

## Safety invariants checked

- input conservation
- output conservation
- non-negativity
- user rebate recoverability
- filler payout boundedness
- protocol capture boundedness

## How to run

Install TLC (part of the TLA+ toolbox) or use the command-line tools:

```bash
# Using the TLA+ command-line tools
cd spec
tlc AsyncSwap.tla -config AsyncSwap.cfg
```

Or open in the TLA+ Toolbox IDE and run the model checker from there.

## Model checking parameters

The `.cfg` file uses small constants for tractable model checking:

- `MaxInput = 10`
- `MaxOutput = 10`
- `MaxFee = 3`
- `MaxTime = 5`

These are intentionally small so the state space is explorable.
For deeper checking, increase these values (at the cost of longer run times).

## Relationship to other artifacts

- `docs/asyncswap_formal_spec.md` — plain-English V1 spec (reviewed)
- `docs/asyncswap_state_machine.md` — state machine reference doc
- `src/uv4/asyncswap_state_machine.py` — executable Python model
- `src/uv4/asyncswap_value.py` — USD-value fairness model
