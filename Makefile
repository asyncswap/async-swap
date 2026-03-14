.PHONY: help deploy-asyncswap deploy-governance transfer-asyncswap-ownership set-token-minter schedule-ownership-accept execute-ownership-accept revoke-bootstrap-roles deploy-oracle-adapter set-pool-oracle set-unichain-sepolia-eth-usdc-oracle print-pool-id demo-deploy-tokens demo-init-pool demo-init-native-pool demo-create-order demo-fill-order deploy-all deploy-local require-broadcast

ifneq (,$(wildcard .env))
include .env
export
endif

CHAIN ?= anvil
RUN_MODE ?= broadcast
RPC_URL ?= http://127.0.0.1:8545
TIMELOCK_DELAY ?= 60
VOTING_DELAY ?= 1
VOTING_PERIOD ?= 10
PROPOSAL_THRESHOLD ?= 100000000000000000000
QUORUM_PERCENT ?= 4
AUTO_EXECUTE_LOCAL ?= true

ifeq ($(CHAIN),anvil)
FORGE_SCRIPT = forge script --rpc-url $(RPC_URL) --sender $(DEPLOYER_ADDRESS) --unlocked --broadcast -vvvv
else
FORGE_SCRIPT = forge script --rpc-url $(RPC_URL) --account $(ACCOUNT) --sender $(DEPLOYER_ADDRESS) --broadcast -vvvv --no-cache
endif

help:
	@printf "Available targets:\n"
	@printf "  deploy-asyncswap          Deploy AsyncSwap and PoolManager (PoolManager only deploys on anvil unless overridden)\n"
	@printf "  deploy-governance         Deploy AsyncToken, TimelockController, and AsyncGovernor\n"
	@printf "  transfer-asyncswap-ownership Transfer AsyncSwap ownership to the timelock\n"
	@printf "  set-token-minter             Set AsyncToken minter to the timelock\n"
	@printf "  schedule-ownership-accept Schedule AsyncSwap.acceptOwnership() through the timelock\n"
	@printf "  execute-ownership-accept  Execute the scheduled AsyncSwap.acceptOwnership() call after the timelock delay\n"
	@printf "  revoke-bootstrap-roles    Remove temporary deployer timelock roles after bootstrap is complete\n"
	@printf "  deploy-oracle-adapter     Deploy the Chronicle oracle adapter\n"
	@printf "  set-pool-oracle           Configure the adapter and set oracle config for a pool\n"
	@printf "  set-unichain-sepolia-eth-usdc-oracle Configure Chronicle ETH/USD oracle defaults for native/USDC on Unichain Sepolia\n"
	@printf "  print-pool-id             Print the deterministic PoolId for token pair + hook\n"
	@printf "  deploy-all                Run steps 00-04 in order\n"
	@printf "  deploy-local              Run the full local anvil flow, including timelock fast-forward and steps 05-06\n"
	@printf "  demo-deploy-tokens        Deploy local demo ERC20 tokens for swap flow testing\n"
	@printf "  demo-init-pool            Initialize an ERC20/ERC20 AsyncSwap demo pool\n"
	@printf "  demo-init-native-pool     Initialize a native/token AsyncSwap demo pool\n"
	@printf "  demo-create-order         Create a demo AsyncSwap order using the local scripts\n"
	@printf "  demo-fill-order           Fill the demo AsyncSwap order using the local scripts\n"

require-account-env:
	@test -n "$(DEPLOYER_ADDRESS)" || (echo "Missing DEPLOYER_ADDRESS" && exit 1)
	@if [ "$(CHAIN)" != "anvil" ]; then \
		test -n "$(ACCOUNT)" || (echo "Missing ACCOUNT" && exit 1); \
	fi

require-broadcast:
	@test "$(RUN_MODE)" = "broadcast" || (echo "This target requires RUN_MODE=broadcast" && exit 1)

deploy-asyncswap: require-account-env
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/00_DeployAsyncSwap.s.sol:DeployAsyncSwapScript

deploy-governance: require-account-env
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) TIMELOCK_DELAY=$(TIMELOCK_DELAY) VOTING_DELAY=$(VOTING_DELAY) VOTING_PERIOD=$(VOTING_PERIOD) PROPOSAL_THRESHOLD=$(PROPOSAL_THRESHOLD) QUORUM_PERCENT=$(QUORUM_PERCENT) $(FORGE_SCRIPT) script/01_DeployGovernance.s.sol:DeployGovernanceScript

transfer-asyncswap-ownership: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/02_TransferAsyncSwapOwnership.s.sol:TransferAsyncSwapOwnershipScript

set-token-minter: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/03_SetAsyncTokenMinter.s.sol:SetAsyncTokenMinterScript

schedule-ownership-accept: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/04_ScheduleAsyncSwapOwnershipAcceptance.s.sol:ScheduleAsyncSwapOwnershipAcceptanceScript

execute-ownership-accept: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/05_ExecuteAsyncSwapOwnershipAcceptance.s.sol:ExecuteAsyncSwapOwnershipAcceptanceScript

revoke-bootstrap-roles: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/06_RevokeBootstrapTimelockRoles.s.sol:RevokeBootstrapTimelockRolesScript

deploy-oracle-adapter: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/11_DeployChronicleOracleAdapter.s.sol:DeployChronicleOracleAdapterScript

set-pool-oracle: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/12_SetPoolOracleConfig.s.sol:SetPoolOracleConfigScript

set-unichain-sepolia-eth-usdc-oracle: require-account-env require-broadcast
	@if [ -z "$(POOL_ID)" ]; then echo "Missing POOL_ID" && exit 1; fi
	CHAIN=unichain-sepolia RUN_MODE=$(RUN_MODE) \
	CHRONICLE_ORACLE=0x1a16742c2f612eC46f52687BE5d1731EC12cBD89 \
	TOKEN0_ADDRESS=0x0000000000000000000000000000000000000000 \
	TOKEN1_ADDRESS=0x31d0220469e10c4E71834a79b1f276d740d3768F \
	ORACLE_INVERSE=false \
	ORACLE_SCALE_NUMERATOR=1000000 \
	ORACLE_SCALE_DENOMINATOR=1000000000000000000 \
	$(FORGE_SCRIPT) script/12_SetPoolOracleConfig.s.sol:SetPoolOracleConfigScript

print-pool-id:
	bash script/print-pool-id.sh

deploy-all: deploy-asyncswap deploy-governance transfer-asyncswap-ownership set-token-minter schedule-ownership-accept

demo-deploy-tokens: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/07_DeployDemoTokens.s.sol:DeployDemoTokensScript

demo-init-pool: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/08_InitializeDemoPool.s.sol:InitializeDemoPoolScript

demo-init-native-pool: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/08_InitializeNativeTokenPool.s.sol:InitializeNativeTokenPoolScript

demo-create-order: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/09_CreateDemoOrder.s.sol:CreateDemoOrderScript

demo-fill-order: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/10_FillDemoOrder.s.sol:FillDemoOrderScript

deploy-local:
	$(MAKE) RUN_MODE=broadcast deploy-all
	@if [ "$(AUTO_EXECUTE_LOCAL)" = "true" ]; then \
		printf "\n==> Advancing local timelock delay\n"; \
		cast rpc --rpc-url $(RPC_URL) evm_increaseTime $(TIMELOCK_DELAY) >/dev/null; \
		cast rpc --rpc-url $(RPC_URL) evm_mine >/dev/null; \
		$(MAKE) RUN_MODE=broadcast execute-ownership-accept; \
		$(MAKE) RUN_MODE=broadcast revoke-bootstrap-roles; \
	else \
		printf "\nAUTO_EXECUTE_LOCAL=false, skipping execute/revoke steps.\n"; \
	fi
