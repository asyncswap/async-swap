import { ponder } from "ponder:registry";
import schema from "ponder:schema";

ponder.on("CsmmHook:AsyncSwapOrder", async ({ event, context }) => {
	await context.db
		.insert(schema.order)
		.values({
			chainId: context.network.chainId,
			owner: event.args.owner,
			poolId: event.args.poolId,
			zeroForOne: event.args.zeroForOne,
			amountIn: event.args.amountIn,
			timestamp: event.block.timestamp,
		})
		.onConflictDoUpdate((row) => ({
			orderStatus: false,
			amountIn: row.amountIn + event.args.amountIn,
			timestamp: event.block.timestamp,
		}));
});

ponder.on("CsmmHook:AsyncOrderFilled", async ({ event, context }) => {
	await context.db
		.insert(schema.order)
		.values({
			chainId: context.network.chainId,
			poolId: event.args.poolId,
			owner: event.args.owner,
			zeroForOne: event.args.zeroForOne,
			amountIn: event.args.amount,
			timestamp: event.block.timestamp,
			orderStatus: false,
		})
		.onConflictDoUpdate((row) => {
			const orderDiff = row.amountIn - event.args.amount;
			if (orderDiff === BigInt(0)) {
				return {
					amountIn: orderDiff,
					orderStatus: true,
					timestamp: event.block.timestamp,
				};
			}
			return {
				orderStatus: false,
				amountIn: orderDiff,
				timestamp: event.block.timestamp,
			};
		});
});
