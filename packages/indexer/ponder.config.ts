import { createConfig } from "ponder";
import { http, getAddress, hexToNumber } from "viem";
import type { Hex } from "viem";
import DeployPoolManager from "../../broadcast/00_DeployPoolManager.s.sol/130/run-latest.json";
import DeployHook from "../../broadcast/01_DeployHook.s.sol/130/run-latest.json";
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
		unichain: {
			chainId: 130,
			transport: http("http://127.0.0.1:8545"),
			disableCache: true,
		},
	},
	contracts: {
		PoolManager: {
			network: {
				unichain: {
					address: "0x1F98400000000000000000000000000000000004",
					startBlock: 27859493, // poolManagerStartBlock,
				},
			},
			abi: PoolManagerAbi,
		},
		CsmmHook: {
			network: {
				unichain: {
					address: hookAddress,
					startBlock: 27859493, // hookStartBlock,
				},
			},
			abi: AsyncSwapAbi,
		},
	},
});
