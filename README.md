## AsyncSwap

AsyncSwap is an intent-based async swap hook built on Uniswap v4.

Instead of executing trades against AMM liquidity immediately, AsyncSwap records a priced order at a chosen tick, escrows the user's input, and lets external fillers complete the output side later.

### How it works

1. A user submits a swap with a price (tick), amount, and optional deadline
2. The hook escrows the input tokens and records the order
3. Fillers (solvers) see the order and deliver the output tokens to the user
4. The filler receives proportional input claim tokens in return
5. If unfilled, the user can cancel and reclaim their full input

### Not a CLOB

AsyncSwap is not an order book. There is no matching engine, no price-time priority, and orders do not cross against each other. Instead, external fillers choose which orders to fill and when. This makes AsyncSwap closer to an intent/RFQ system (like UniswapX or CoW Protocol) than a central limit order book.

| | CLOB | AsyncSwap |
|---|---|---|
| Price-level orders | yes | yes |
| Automatic matching | yes | no |
| External fillers | no | yes |
| Price-time priority | yes | no |
| Orders cross each other | yes | no |
| Async settlement | no | yes |

### Features

- async order creation, partial fill, and cancellation
- order expiry with permissionless keeper cleanup
- native input and native output support
- configurable protocol fee with fee refund toggle (fees only on filled volume)
- one-time governance token rewards for swappers, fillers, and keepers
- pause / unpause controls
- treasury and per-pool dynamic fee governance
- governance execution through `AsyncGovernor + TimelockController`

## Repo Guide

- `src/AsyncSwap.sol` - main hook contract
- `src/IntentAuth.sol` - ownership, treasury, fee policy, and pause controls
- `src/AsyncRouter.sol` - router callback and exact-input settlement path
- `src/governance/` - token + governor contracts
- `script/README.md` - deployment and governance runbook

## Development

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

### Anvil

```shell
anvil
```

### Deploy

```shell
forge script script/00_DeployAsyncSwap.s.sol:DeployAsyncSwapScript \
  --rpc-url $RPC_URL \
  --account <foundry-account-name> \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

For the full deployment, governance, and operator runbook, see:

```text
script/README.md
```

### Cast

```shell
cast <subcommand>
```

### Help

```shell
forge --help
anvil --help
cast --help
```
