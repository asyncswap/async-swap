import { createConfig } from "ponder";
import { http, getAddress, hexToNumber } from "viem";
import type { Hex } from "viem";
import DeployPoolManager from "../../broadcast/00_DeployPoolManager.s.sol/31337/run-latest.json";
import DeployHook from "../../broadcast/01_DeployHook.s.sol/31337/run-latest.json";
import { AsyncSwapAbi } from "./abis/AsyncSwap";
import { PoolManagerAbi } from "./abis/PoolManagerAbi";

const poolManagerAddress = getAddress(
	DeployPoolManager.transactions[0]?.contractAddress as Hex,
);
const poolManagerStartBlock = hexToNumber(
	DeployPoolManager.receipts[0]?.blockNumber as Hex,
);

const hookAddress = getAddress(
	DeployHook.transactions[0]?.contractAddress as Hex,
);
const hookStartBlock = hexToNumber(DeployHook.receipts[0]?.blockNumber as Hex);

export default createConfig({
	networks: {
		anvil: {
			chainId: 31337,
			transport: http("http://127.0.0.1:8545"),
			disableCache: true,
		},
	},
	contracts: {
		PoolManager: {
			network: {
				anvil: {
					address: poolManagerAddress,
					startBlock: poolManagerStartBlock,
				},
			},
			abi: PoolManagerAbi,
		},
		CsmmHook: {
			network: {
				anvil: {
					address: hookAddress,
					startBlock: hookStartBlock,
				},
			},
			abi: AsyncSwapAbi,
		},
	},
});
