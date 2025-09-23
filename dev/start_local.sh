#!/bin/bash
forge script --broadcast -f localhost:8545 --account anvil -vvvv script/00_DeployPoolManager.s.sol --password yes
sleep 2
forge script --broadcast -f localhost:8545 --account anvil -vvvv script/01_DeployHook.s.sol --password yes
sleep 2
forge script --broadcast -f localhost:8545 --account anvil -vvvv script/02_InitilizePool.s.sol --password yes
sleep 2
forge script --broadcast --rpc-url localhost:8545 --account anvil -vvvv script/04_Swap.s.sol --password yes
sleep 2
forge script --broadcast --rpc-url localhost:8545 --account anvil -vvvv script/05_ExecuteOrder.s.sol --password yes
