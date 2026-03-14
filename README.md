## AsyncSwap

AsyncSwap is an intent-based async swap hook built on Uniswap v4.

Instead of executing the entire trade against AMM liquidity immediately, the hook records a priced order at a chosen tick, escrows the user's input, and lets fillers complete the output side later. The protocol supports:

- async order creation, partial fill, and cancellation
- native input and native output handling
- configurable protocol fee behavior via the fee refund toggle
- pause / unpause controls
- treasury and per-pool fee governance
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
