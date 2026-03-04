import { index, onchainTable, primaryKey } from "ponder";

// One row per pool, created on Initialize event
export const pool = onchainTable(
  "pool",
  (t) => ({
    poolId: t.hex().notNull(),
    currency0: t.hex().notNull(),
    currency1: t.hex().notNull(),
    fee: t.integer().notNull(),
    tickSpacing: t.integer().notNull(),
    hooks: t.hex().notNull(),
    sqrtPriceX96: t.bigint().notNull(),
    tick: t.integer().notNull(),
    chainId: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.poolId, table.chainId] }),
  }),
);

// One row per Swap event — core table for benchmark simulation
export const swap = onchainTable(
  "swap",
  (t) => ({
    id: t.text().notNull(),
    poolId: t.hex().notNull(),
    sender: t.hex().notNull(),
    amount0: t.bigint().notNull(),
    amount1: t.bigint().notNull(),
    sqrtPriceX96: t.bigint().notNull(),
    liquidity: t.bigint().notNull(),
    tick: t.integer().notNull(),
    fee: t.integer().notNull(),
    zeroForOne: t.boolean().notNull(),
    blockNumber: t.bigint().notNull(),
    chainId: t.integer().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.id, table.chainId] }),
    poolIdIndex: index().on(table.poolId),
    blockNumberIndex: index().on(table.blockNumber),
    // composite index for grouping swaps by pool+block (benchmark query pattern)
    poolBlockIndex: index().on(table.poolId, table.blockNumber),
  }),
);

// One row per ModifyLiquidity event
export const liquidityEvent = onchainTable(
  "liquidity_event",
  (t) => ({
    id: t.text().notNull(),
    poolId: t.hex().notNull(),
    sender: t.hex().notNull(),
    tickLower: t.integer().notNull(),
    tickUpper: t.integer().notNull(),
    liquidityDelta: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    chainId: t.integer().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.id, table.chainId] }),
    poolIdIndex: index().on(table.poolId),
    blockNumberIndex: index().on(table.blockNumber),
  }),
);
