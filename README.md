## Async Swap

## Documentation

## Usage

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

### Governance Deployment

These scripts use `vm.startBroadcast()` and are intended to be run with a Foundry account / keystore setup (`--account` + `--sender`), not a raw `PRIVATE_KEY` env var.

Required environment variables:

```shell
export DEPLOYER_ADDRESS=0x...
export TIMELOCK_DELAY=86400
export VOTING_DELAY=1
export VOTING_PERIOD=10
export PROPOSAL_THRESHOLD=100000000000000000000
export QUORUM_PERCENT=4
```

Deploy governance contracts:

```shell
forge script script/01_DeployGovernance.s.sol:DeployGovernanceScript \
  --rpc-url $RPC_URL \
  --account <foundry-account-name> \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

This deploys:
- `AsyncToken`
- `TimelockController`
- `AsyncGovernor`

Bootstrap notes:
- the deployer is given temporary timelock proposer power so the initial ownership transfer can be scheduled
- the governor is also granted proposer power
- executors are open (`address(0)`)

Wire governance to `AsyncSwap`:

```shell
export TIMELOCK_ADDRESS=0x...
export ASYNCSWAP_ADDRESS=0x...

forge script script/02_WireGovernance.s.sol:WireGovernanceToAsyncSwapScript \
  --rpc-url $RPC_URL \
  --account <foundry-account-name> \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

Transfer token minting to timelock:

```shell
export ASYNC_TOKEN_ADDRESS=0x...

forge script script/02_WireGovernance.s.sol:TransferAsyncTokenMinterToTimelockScript \
  --rpc-url $RPC_URL \
  --account <foundry-account-name> \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

Schedule `AsyncSwap.acceptOwnership()` through the timelock:

```shell
forge script script/02_WireGovernance.s.sol:AcceptAsyncSwapOwnershipViaTimelockScript \
  --rpc-url $RPC_URL \
  --account <foundry-account-name> \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

After the timelock delay elapses, execute ownership acceptance:

```shell
forge script script/02_WireGovernance.s.sol:ExecuteAsyncSwapOwnershipAcceptanceScript \
  --rpc-url $RPC_URL \
  --account <foundry-account-name> \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

Finally, revoke bootstrap timelock privileges from the deployer:

```shell
export GOVERNOR_ADDRESS=0x...

forge script script/02_WireGovernance.s.sol:RevokeBootstrapTimelockRolesScript \
  --rpc-url $RPC_URL \
  --account <foundry-account-name> \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

Recommended deployment order:
1. `DeployAsyncSwapScript`
2. `DeployGovernanceScript`
3. `WireGovernanceToAsyncSwapScript`
4. `TransferAsyncTokenMinterToTimelockScript`
5. `AcceptAsyncSwapOwnershipViaTimelockScript`
6. wait `TIMELOCK_DELAY`
7. `ExecuteAsyncSwapOwnershipAcceptanceScript`
8. `RevokeBootstrapTimelockRolesScript`

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
