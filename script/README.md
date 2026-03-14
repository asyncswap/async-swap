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
13. `11_DeployChronicleOracleAdapter.s.sol`
14. `12_SetPoolOracleConfig.s.sol`

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
make deploy-oracle-adapter
make set-pool-oracle
make print-pool-id
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

## Oracle Deployment

Deploy the Chronicle oracle adapter:

```shell
make deploy-oracle-adapter
```

Then configure a pool oracle:

```shell
export ORACLE_ADAPTER_ADDRESS=0x...
export CHRONICLE_ORACLE=0x1a16742c2f612eC46f52687BE5d1731EC12cBD89
export CHRONICLE_SELF_KISSER=0x7AB42CC558fc92EC990B22E663E5a7bc5879fc9f
export POOL_ID=0x...
export ORACLE_MAX_AGE=300
export ORACLE_MAX_DEVIATION_BPS=100
export USER_SURPLUS_BPS=5000
export FILLER_SURPLUS_BPS=2500
export PROTOCOL_SURPLUS_BPS=2500

make set-pool-oracle
```

### Unichain Sepolia native ETH / USDC example

Known addresses:

```shell
export CHAIN=unichain-sepolia
export TOKEN0_ADDRESS=0x0000000000000000000000000000000000000000
export TOKEN1_ADDRESS=0x31d0220469e10c4E71834a79b1f276d740d3768F
export CHRONICLE_ORACLE=0x1a16742c2f612eC46f52687BE5d1731EC12cBD89
export CHRONICLE_SELF_KISSER=0x7AB42CC558fc92EC990B22E663E5a7bc5879fc9f
```

On `CHAIN=unichain-sepolia`, these two Chronicle addresses are used as defaults by the scripts, so you only need to override them if Chronicle changes deployments.

Print the `POOL_ID` first:

```shell
make print-pool-id
```

Then configure the pool oracle:

```shell
export POOL_ID=0x...
export ORACLE_MAX_AGE=300
export ORACLE_MAX_DEVIATION_BPS=100
export USER_SURPLUS_BPS=5000
export FILLER_SURPLUS_BPS=2500
export PROTOCOL_SURPLUS_BPS=2500

make set-unichain-sepolia-eth-usdc-oracle
```

That convenience target uses:
- `ORACLE_INVERSE=false`
- `ORACLE_SCALE_NUMERATOR=1000000`
- `ORACLE_SCALE_DENOMINATOR=1000000000000000000`

This maps an 18-decimal ETH/USD Chronicle price into the native/USDC pool price domain.

To compute the deterministic `POOL_ID` for a token pair and hook:

```shell
export TOKEN0_ADDRESS=0x...
export TOKEN1_ADDRESS=0x...

make print-pool-id
```

Notes:
- the adapter is configured per `poolId`
- Chronicle access may require the adapter contract to be whitelisted / self-kissed on the target network
- the current adapter uses `sqrtPriceX96` as the oracle output format for surplus capture math

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
