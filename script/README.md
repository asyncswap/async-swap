## Script Runbook

This directory contains the deployment and governance-connection runbook for AsyncSwap.

Scripts use `vm.startBroadcast()` and are intended to be run with a Foundry account / keystore setup (`--account` + `--sender`), not a raw `PRIVATE_KEY` env var.

## Environment Variables

If you already keep deployment values in a project `.env`, the `Makefile` will load it automatically.

Minimum expected values:

```shell
export DEPLOYER_ADDRESS=0x...
export ACCOUNT=<foundry-account-name>
export CHAIN=anvil
export RUN_MODE=broadcast
```

For `CHAIN=anvil`, `make` uses `--unlocked` automatically, so `ACCOUNT` is not required for local deployment.

If `RPC_URL` is omitted, the shell script defaults to:

```shell
http://127.0.0.1:8545
```

Optional governance env vars:

```shell
export TIMELOCK_DELAY=86400
export VOTING_DELAY=1
export VOTING_PERIOD=10
export PROPOSAL_THRESHOLD=100000000000000000000
export QUORUM_PERCENT=4
export AUTO_EXECUTE_LOCAL=true
```

## Numbered Script Sequence

1. `00_DeployAsyncSwap.s.sol`
2. `01_DeployGovernance.s.sol`
3. `02_TransferAsyncSwapOwnership.s.sol`
4. `03_SetAsyncTokenMinter.s.sol`
5. `04_ScheduleAsyncSwapOwnershipAcceptance.s.sol`
6. `05_ExecuteAsyncSwapOwnershipAcceptance.s.sol`
7. `06_RevokeBootstrapTimelockRoles.s.sol`
8. `07_DeployDemoTokens.s.sol`
9. `08_InitializeDemoPool.s.sol`
10. `08_InitializeNativeTokenPool.s.sol`
11. `09_CreateDemoOrder.s.sol`
12. `10_FillDemoOrder.s.sol`

## Deploy AsyncSwap

```shell
forge script script/00_DeployAsyncSwap.s.sol:DeployAsyncSwapScript \
  --rpc-url $RPC_URL \
  --account $ACCOUNT \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

Notes:
- on `CHAIN=anvil`, the script deploys a fresh `PoolManager` unless `POOLMANAGER_ADDRESS` is provided
- on supported public chains, the script uses the chain-specific `PoolManager` address from `script/contracts.txt`

## Deploy Governance

```shell
forge script script/01_DeployGovernance.s.sol:DeployGovernanceScript \
  --rpc-url $RPC_URL \
  --account $ACCOUNT \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

This deploys:
- `AsyncToken`
- `TimelockController`
- `AsyncGovernor`

Bootstrap notes:
- the deployer is granted temporary timelock proposer power so the initial ownership transfer can be scheduled
- the governor is also granted proposer power
- executors are open (`address(0)`)

## Connect Governance to AsyncSwap

Transfer `AsyncSwap` ownership to the timelock:

```shell
forge script script/02_TransferAsyncSwapOwnership.s.sol:TransferAsyncSwapOwnershipScript \
  --rpc-url $RPC_URL \
  --account $ACCOUNT \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

Transfer token minting to the timelock:

```shell
forge script script/03_SetAsyncTokenMinter.s.sol:SetAsyncTokenMinterScript \
  --rpc-url $RPC_URL \
  --account $ACCOUNT \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

Schedule `AsyncSwap.acceptOwnership()` via timelock:

```shell
forge script script/04_ScheduleAsyncSwapOwnershipAcceptance.s.sol:ScheduleAsyncSwapOwnershipAcceptanceScript \
  --rpc-url $RPC_URL \
  --account $ACCOUNT \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

Execute `AsyncSwap.acceptOwnership()` after the timelock delay:

```shell
forge script script/05_ExecuteAsyncSwapOwnershipAcceptance.s.sol:ExecuteAsyncSwapOwnershipAcceptanceScript \
  --rpc-url $RPC_URL \
  --account $ACCOUNT \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

Revoke bootstrap roles from the deployer:

```shell
forge script script/06_RevokeBootstrapTimelockRoles.s.sol:RevokeBootstrapTimelockRolesScript \
  --rpc-url $RPC_URL \
  --account $ACCOUNT \
  --sender $DEPLOYER_ADDRESS \
  --broadcast
```

## Make Orchestration

Preferred usage is via `make`:

```shell
make deploy-all
```

For local Anvil end-to-end execution:

```shell
make deploy-local
```

If `CHAIN=anvil` and `AUTO_EXECUTE_LOCAL=true`, the make flow will automatically:
- advance the local timelock delay
- execute step `05`
- execute step `06`

`deploy-local` forces `RUN_MODE=broadcast` so chained ownership/timelock steps do not accidentally consume dry-run outputs.

Useful individual targets:

```shell
make deploy-asyncswap
make deploy-governance
make transfer-asyncswap-ownership
make set-token-minter
make schedule-ownership-accept
make execute-ownership-accept
make revoke-bootstrap-roles
make demo-deploy-tokens
make demo-init-pool
make demo-init-native-pool
make demo-create-order
make demo-fill-order
```

The previous shell wrapper has been removed to keep a single orchestration path.

## Helper Behavior

`ScriptHelper.sol` reads configuration from env vars:
- `CHAIN`
- `RUN_MODE`

If explicit contract addresses are not provided, it reads prior deployment outputs from `broadcast/<script>/<chain>/...` files.

Named helper getters resolve:
- deployed `AsyncSwap`
- deployed `AsyncToken`
- deployed `TimelockController`
- deployed `AsyncGovernor`
- chain-specific `PoolManager`

## Recommended Local Flow

For a local Anvil rehearsal, the intended path is:

```shell
make deploy-local
```

This will:
1. deploy `AsyncSwap`
2. deploy governance contracts
3. connect ownership and token minting to the timelock
4. schedule ownership acceptance
5. fast-forward the local timelock delay
6. execute ownership acceptance
7. revoke bootstrap deployer roles

## Demo Swap Flow (Local)

ERC20/ERC20 demo flow:

```shell
make demo-deploy-tokens
make demo-init-pool
make demo-create-order
make demo-fill-order
```

Native/token pool initialization:

```shell
make demo-init-native-pool
```

Useful env vars for the demo flow:

```shell
export USER_ADDRESS=0x...
export FILLER_ADDRESS=0x...
export DEMO_MINT_AMOUNT=1000000000000000000000000
export ORDER_AMOUNT_IN=1000000000000000000
export ORDER_TICK=0
export MIN_AMOUNT_OUT=0
export ZERO_FOR_ONE=true
export FILL_AMOUNT=0   # if omitted, fill script uses full remaining output
```

Notes:
- `07_DeployDemoTokens` mints both demo ERC20s to both the user and the filler
- `08_InitializeDemoPool` initializes an ERC20/ERC20 pool using the deployed demo tokens
- `08_InitializeNativeTokenPool` initializes a native/token pool using `TOKEN1_ADDRESS` or the second deployed demo token
- `09_CreateDemoOrder` approves the hook router and submits the order from `USER_ADDRESS`
- `10_FillDemoOrder` approves the hook and fills from `FILLER_ADDRESS`
