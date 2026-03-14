.PHONY: help deploy-asyncswap deploy-governance connect-asyncswap-owner connect-token-minter schedule-ownership-accept execute-ownership-accept revoke-bootstrap-roles deploy-all deploy-local require-broadcast

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

FORGE_SCRIPT = forge script --rpc-url $(RPC_URL) --account $(ACCOUNT) --sender $(DEPLOYER_ADDRESS) --broadcast -vvvv --no-cache

help:
	@printf "Available targets:\n"
	@printf "  deploy-asyncswap\n"
	@printf "  deploy-governance\n"
	@printf "  connect-asyncswap-owner\n"
	@printf "  connect-token-minter\n"
	@printf "  schedule-ownership-accept\n"
	@printf "  execute-ownership-accept\n"
	@printf "  revoke-bootstrap-roles\n"
	@printf "  deploy-all\n"
	@printf "  deploy-local\n"

require-account-env:
	@test -n "$(ACCOUNT)" || (echo "Missing ACCOUNT" && exit 1)
	@test -n "$(DEPLOYER_ADDRESS)" || (echo "Missing DEPLOYER_ADDRESS" && exit 1)

require-broadcast:
	@test "$(RUN_MODE)" = "broadcast" || (echo "This target requires RUN_MODE=broadcast" && exit 1)

deploy-asyncswap: require-account-env
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/00_DeployAsyncSwap.s.sol:DeployAsyncSwapScript

deploy-governance: require-account-env
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) TIMELOCK_DELAY=$(TIMELOCK_DELAY) VOTING_DELAY=$(VOTING_DELAY) VOTING_PERIOD=$(VOTING_PERIOD) PROPOSAL_THRESHOLD=$(PROPOSAL_THRESHOLD) QUORUM_PERCENT=$(QUORUM_PERCENT) $(FORGE_SCRIPT) script/01_DeployGovernance.s.sol:DeployGovernanceScript

connect-asyncswap-owner: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/02_ConnectAsyncSwapOwnership.s.sol:ConnectGovernanceToAsyncSwapScript

connect-token-minter: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/03_ConnectAsyncTokenMinter.s.sol:ConnectAsyncTokenMinterToTimelockScript

schedule-ownership-accept: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/04_ScheduleAsyncSwapOwnershipAcceptance.s.sol:ScheduleAsyncSwapOwnershipAcceptanceScript

execute-ownership-accept: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/05_ExecuteAsyncSwapOwnershipAcceptance.s.sol:ExecuteAsyncSwapOwnershipAcceptanceScript

revoke-bootstrap-roles: require-account-env require-broadcast
	CHAIN=$(CHAIN) RUN_MODE=$(RUN_MODE) $(FORGE_SCRIPT) script/06_RevokeBootstrapTimelockRoles.s.sol:RevokeBootstrapTimelockRolesScript

deploy-all: deploy-asyncswap deploy-governance connect-asyncswap-owner connect-token-minter schedule-ownership-accept

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
