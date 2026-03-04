import { ponder } from "ponder:registry";
import { pool, swap, liquidityEvent } from "ponder:schema";

// Index pool creation — one row per unique pool
ponder.on("PoolManager:Initialize", async ({ event, context }) => {
  await context.db
    .insert(pool)
    .values({
      poolId: event.args.id,
      currency0: event.args.currency0,
      currency1: event.args.currency1,
      fee: event.args.fee,
      tickSpacing: event.args.tickSpacing,
      hooks: event.args.hooks,
      sqrtPriceX96: event.args.sqrtPriceX96,
      tick: event.args.tick,
      chainId: context.chain.id,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
    })
    .onConflictDoNothing();
});

// Index every swap — core data for benchmark simulation.
// zeroForOne: negative amount0 means token0 was sold (zeroForOne=true).
ponder.on("PoolManager:Swap", async ({ event, context }) => {
  const zeroForOne = event.args.amount0 < 0n;

  await context.db.insert(swap).values({
    id: event.id,
    poolId: event.args.id,
    sender: event.transaction.from,
    amount0: event.args.amount0,
    amount1: event.args.amount1,
    sqrtPriceX96: event.args.sqrtPriceX96,
    liquidity: event.args.liquidity,
    tick: event.args.tick,
    fee: event.args.fee,
    zeroForOne,
    blockNumber: event.block.number,
    chainId: context.chain.id,
    timestamp: event.block.timestamp,
  });
});

// Index liquidity events — useful for tracking pool depth over time
ponder.on("PoolManager:ModifyLiquidity", async ({ event, context }) => {
  await context.db.insert(liquidityEvent).values({
    id: event.id,
    poolId: event.args.id,
    sender: event.transaction.from,
    tickLower: event.args.tickLower,
    tickUpper: event.args.tickUpper,
    liquidityDelta: event.args.liquidityDelta,
    blockNumber: event.block.number,
    chainId: context.chain.id,
    timestamp: event.block.timestamp,
  });
});
