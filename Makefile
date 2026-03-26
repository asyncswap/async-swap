.PHONY: help deploy-asyncswap deploy-governance transfer-asyncswap-ownership set-token-minter schedule-ownership-accept execute-ownership-accept revoke-bootstrap-roles deploy-oracle-adapter set-pool-oracle set-unichain-sepolia-eth-usdc-oracle print-pool-id demo-deploy-tokens demo-init-pool demo-init-native-pool demo-create-order demo-fill-order deploy-all deploy-local deploy-protocol require-broadcast

ifneq (,$(wildcard .env))
include .env
export
endif

CHAIN ?= anvil
RUN_MODE ?= broadcast
CONFIG_FILE := config/deployments.yaml
CONFIG_RPC_URL := $(shell ruby script/read-config.rb $(CONFIG_FILE) chains.$(CHAIN).rpcUrl)
cfg = $(shell ruby script/read-config.rb $(CONFIG_FILE) $(1))
RPC_URL ?= $(if $(CONFIG_RPC_URL),$(CONFIG_RPC_URL),http://127.0.0.1:8545)
TIMELOCK_DELAY ?= 60
VOTING_DELAY ?= 1
VOTING_PERIOD ?= 10
PROPOSAL_THRESHOLD ?= 100000000000000000000
QUORUM_PERCENT ?= 4
AUTO_EXECUTE_LOCAL ?= true

ifeq ($(CHAIN),anvil)
FORGE_SCRIPT = forge script --rpc-url $(RPC_URL) --sender $(DEPLOYER_ADDRESS) --unlocked --broadcast -vvvv --verify
else
FORGE_SCRIPT = forge script --rpc-url $(RPC_URL) --account $(ACCOUNT) --sender $(DEPLOYER_ADDRESS) --broadcast -vvvv --no-cache --verify 
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
	@printf "  deploy-protocol           Full deployment: core + governance + pool + oracle + unpause + harden\n"
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
	$(eval PRESET_CHAIN := unichain-sepolia)
	$(eval PRESET := native-usdc)
	CHAIN=unichain-sepolia RUN_MODE=$(RUN_MODE) \
	CHRONICLE_ORACLE=$(call cfg,chains.$(PRESET_CHAIN).chronicle.ethUsd) \
	CHRONICLE_SELF_KISSER=$(call cfg,chains.$(PRESET_CHAIN).chronicle.selfKisser) \
	TOKEN0_ADDRESS=$(call cfg,pool_presets.$(PRESET_CHAIN).$(PRESET).token0) \
	TOKEN1_ADDRESS=$(call cfg,pool_presets.$(PRESET_CHAIN).$(PRESET).token1) \
	ORACLE_INVERSE=$(call cfg,pool_presets.$(PRESET_CHAIN).$(PRESET).oracle.inverse) \
	ORACLE_SCALE_NUMERATOR=$(call cfg,pool_presets.$(PRESET_CHAIN).$(PRESET).oracle.scaleNumerator) \
	ORACLE_SCALE_DENOMINATOR=$(call cfg,pool_presets.$(PRESET_CHAIN).$(PRESET).oracle.scaleDenominator) \
	ORACLE_MAX_AGE=$(or $(ORACLE_MAX_AGE),$(call cfg,pool_presets.$(PRESET_CHAIN).$(PRESET).oracle.maxAge)) \
	ORACLE_MAX_DEVIATION_BPS=$(or $(ORACLE_MAX_DEVIATION_BPS),$(call cfg,pool_presets.$(PRESET_CHAIN).$(PRESET).oracle.maxDeviationBps)) \
	USER_SURPLUS_BPS=$(or $(USER_SURPLUS_BPS),$(call cfg,pool_presets.$(PRESET_CHAIN).$(PRESET).oracle.userSurplusBps)) \
	FILLER_SURPLUS_BPS=$(or $(FILLER_SURPLUS_BPS),$(call cfg,pool_presets.$(PRESET_CHAIN).$(PRESET).oracle.fillerSurplusBps)) \
	PROTOCOL_SURPLUS_BPS=$(or $(PROTOCOL_SURPLUS_BPS),$(call cfg,pool_presets.$(PRESET_CHAIN).$(PRESET).oracle.protocolSurplusBps)) \
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

# ── Full Protocol Deployment ──────────────────────────────────────────────────
# Deploys everything needed for an operational protocol on a live network:
#   Phase 1: Core contracts + governance (steps 00-04)
#   Phase 2: Wait for timelock delay, then finalize (steps 05-06)
#   Phase 3: Initialize pool + deploy oracle + configure oracle
#   Phase 4: Unpause the protocol
#
# Required env vars:
#   DEPLOYER_ADDRESS, ACCOUNT, CHAIN
#   TOKEN1_ADDRESS           - the non-native token (e.g. USDC)
#   SQRT_PRICE_X96           - initial pool price (default: 1:1)
#   TICK_SPACING             - pool tick spacing (default: 240)
#   TREASURY_ADDRESS         - fee collection address
#
# For oracle configuration on Unichain Sepolia (auto-read from deployments.yaml):
#   POOL_ID                  - set automatically after pool init via print-pool-id
#   CHRONICLE_ORACLE, CHRONICLE_SELF_KISSER - auto from config
#
# Usage:
#   make deploy-protocol CHAIN=unichain-sepolia ACCOUNT=deployer \
#     DEPLOYER_ADDRESS=0x... TOKEN1_ADDRESS=0x... TREASURY_ADDRESS=0x...
# ──────────────────────────────────────────────────────────────────────────────

SQRT_PRICE_X96 ?= 79228162514264337593543950336
TICK_SPACING ?= 240
TREASURY_ADDRESS ?= $(DEPLOYER_ADDRESS)

deploy-protocol: require-account-env require-broadcast
	@printf "\n╔══════════════════════════════════════════════╗\n"
	@printf "║       AsyncSwap Protocol Deployment          ║\n"
	@printf "║  Chain: $(CHAIN)                              \n"
	@printf "╚══════════════════════════════════════════════╝\n\n"
	@# ── Phase 1: Deploy core + governance + schedule ownership ──
	@printf "==> Phase 1: Deploy core contracts + governance\n"
	$(MAKE) deploy-asyncswap
	@printf "\n==> Deploying governance stack\n"
	$(MAKE) deploy-governance
	@printf "\n==> Transferring AsyncSwap ownership to timelock\n"
	$(MAKE) transfer-asyncswap-ownership
	@printf "\n==> Setting token minter to timelock\n"
	$(MAKE) set-token-minter
	@printf "\n==> Scheduling ownership acceptance through timelock\n"
	$(MAKE) schedule-ownership-accept
	@# ── Phase 2: Initialize pool BEFORE ownership transfer executes ──
	@# (deployer is still protocolOwner so can call beforeInitialize)
	@printf "\n==> Phase 2: Initialize native/token pool\n"
	$(MAKE) demo-init-native-pool
	@# ── Phase 3: Deploy + configure oracle BEFORE ownership transfer ──
	@printf "\n==> Phase 3: Deploy oracle adapter\n"
	$(MAKE) deploy-oracle-adapter
	@printf "\n==> Computing pool ID\n"
	$(eval POOL_ID := $(shell bash script/print-pool-id.sh))
	@printf "  Pool ID: $(POOL_ID)\n"
	@# Set oracle config while deployer still owns the hook
	@if [ "$(CHAIN)" = "unichain-sepolia" ]; then \
		printf "\n==> Configuring Chronicle ETH/USD oracle for native/USDC pool\n"; \
		POOL_ID=$(POOL_ID) $(MAKE) set-unichain-sepolia-eth-usdc-oracle; \
	else \
		printf "\n==> Skipping oracle config (not unichain-sepolia). Configure manually with: make set-pool-oracle\n"; \
	fi
	@# ── Phase 4: Set treasury while deployer still owns the hook ──
	@printf "\n==> Setting treasury to $(TREASURY_ADDRESS)\n"
	cast send --rpc-url $(RPC_URL) $(if $(filter anvil,$(CHAIN)),--unlocked,--account $(ACCOUNT)) \
		--from $(DEPLOYER_ADDRESS) \
		$$(cat broadcast/00_DeployAsyncSwap.s.sol/$$(ruby script/read-config.rb $(CONFIG_FILE) chains.$(CHAIN).chainId)/run-latest.json | python3 -c "import sys,json; txs=json.load(sys.stdin)['transactions']; print([t['contractAddress'] for t in txs if t.get('contractName')=='AsyncSwap'][0])") \
		"setTreasury(address)" $(TREASURY_ADDRESS)
	@# ── Phase 5: Unpause while deployer still owns ──
	@printf "\n==> Unpausing protocol\n"
	cast send --rpc-url $(RPC_URL) $(if $(filter anvil,$(CHAIN)),--unlocked,--account $(ACCOUNT)) \
		--from $(DEPLOYER_ADDRESS) \
		$$(cat broadcast/00_DeployAsyncSwap.s.sol/$$(ruby script/read-config.rb $(CONFIG_FILE) chains.$(CHAIN).chainId)/run-latest.json | python3 -c "import sys,json; txs=json.load(sys.stdin)['transactions']; print([t['contractAddress'] for t in txs if t.get('contractName')=='AsyncSwap'][0])") \
		"unpause()"
	@# ── Phase 6: Wait for timelock then finalize governance ──
	@printf "\n==> Phase 6: Waiting for timelock delay ($(TIMELOCK_DELAY)s)\n"
	@if [ "$(CHAIN)" = "anvil" ]; then \
		cast rpc --rpc-url $(RPC_URL) evm_increaseTime $(TIMELOCK_DELAY) >/dev/null; \
		cast rpc --rpc-url $(RPC_URL) evm_mine >/dev/null; \
		printf "  (fast-forwarded on anvil)\n"; \
	else \
		printf "  *** On a live network, wait $(TIMELOCK_DELAY) seconds before running:\n"; \
		printf "      make execute-ownership-accept\n"; \
		printf "      make revoke-bootstrap-roles\n"; \
		printf "  Or re-run this target after the delay has elapsed.\n"; \
	fi
	@# Execute ownership transfer + revoke bootstrap roles
	@printf "\n==> Executing ownership acceptance\n"
	$(MAKE) execute-ownership-accept
	@printf "\n==> Revoking bootstrap roles\n"
	$(MAKE) revoke-bootstrap-roles
	@printf "\n╔══════════════════════════════════════════════╗\n"
	@printf "║         Protocol Deployment Complete!         ║\n"
	@printf "║                                               ║\n"
	@printf "║  AsyncSwap: deployed + unpaused               ║\n"
	@printf "║  Governance: hardened (timelock owns hook)     ║\n"
	@printf "║  Pool: initialized                            ║\n"
	@printf "║  Oracle: configured                           ║\n"
	@printf "║  Treasury: $(TREASURY_ADDRESS)                 \n"
	@printf "╚══════════════════════════════════════════════╝\n"
