import { createConfig } from "ponder";
import { PoolManagerAbi } from "./abis/PoolManagerAbi";

// Uniswap V4 PoolManager — same address on Unichain
const POOL_MANAGER_ADDRESS = "0x1F98400000000000000000000000000000000004" as const;

// Adjust startBlock to trade off history vs. sync time.
// V4 launched on Unichain around block 3_000_000.
const START_BLOCK = Number(process.env.START_BLOCK ?? 3_000_000);

export default createConfig({
  chains: {
    unichain: {
      id: 130,
      rpc: process.env.PONDER_RPC_URL ?? "https://mainnet.unichain.org",
    },
  },
  contracts: {
    PoolManager: {
      chain: "unichain",
      abi: PoolManagerAbi,
      address: POOL_MANAGER_ADDRESS,
      startBlock: START_BLOCK,
    },
  },
});
