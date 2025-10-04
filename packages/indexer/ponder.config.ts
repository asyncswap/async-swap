import { createConfig } from "ponder";
import { http, getAddress } from "viem";
import type { Hex } from "viem";
import DeployHook from "../../broadcast/01_DeployHook.s.sol/130/run-latest.json";
import { AsyncSwapAbi } from "./abis/AsyncSwap";
import { PoolManagerAbi } from "./abis/PoolManagerAbi";

const hookAddress = getAddress(
	DeployHook.transactions[0]?.contractAddress as Hex,
);

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
					startBlock: 28799000, // poolManagerStartBlock,
				},
			},
			abi: PoolManagerAbi,
		},
		CsmmHook: {
			network: {
				unichain: {
					address: hookAddress,
					startBlock: 28799000, // hookStartBlock,
				},
			},
			abi: AsyncSwapAbi,
		},
	},
});
