# Async Swap protocol

The async swap protocol mechanics.

## User actions

- Swap using router
- Withdraw using router

## Filler actions

- Deposit to router
- Claim user swap orders

## Router actions

- Swap on behalf of user
- Withdraw on behalf of user
- Fill orders on behalf of filler

## Hook actions

- Store initial swap amounts
- Release swap amounts to filler
- Release filled amounts to user
- Withdraw swap amounts to user

## Ordering actions

1. A chosen algorithm to reorder the following transactions in the pool.
    1. Swaps
    2. Add liquidity
    3. Remove liquidity
    4. Donate

## On swap

1. First swap on the sequencer in a block
    1. Hook contract receives swap
    2. Hook mints claims for swap
    3. Hook begins ordering volatility calculation
2. On subsequent swaps.
    1. Hook mints claims for other swaps of same block (or k blocks)
    2. Hook accumulates status quo volatility
3. At end of block
    1. Hook has accumated final volatility measure
4. At start of new block or (k + 1 block)
    1. Hook receives new k + 1 block swaps and accumulates new volatility
    2. Hook clears from k - 1 blocks on afterSwap,afterLiquidity..after_
    3. Hook checks for block spacing on first vs last block
    4. If volatility is less than or equal to block vol, we accept order.
    5. If block is already mazimally orderes, volatility will be equal.
    6. If volatility was better we acknowledge users that were maximally advantaged.

## V1 ordering algorithm

1. Order orders by increasing volume (smallest to largest)
2. Alternate the buy / sell (zeroForOne)
3. Check poolId for orders.
    - if hook is managing different pools, we need to submit.
    - Or maybe there is no need to distinguish
    - PoolId is derived from token1, token2 and hook, and fee
    - No need to sort by Id since eitherway we have sorted volume

3. Add liquidity transactions before swap.
4. Remove liquidity actions after the swap.

## Other thoughts

- Prop amms : <https://x.com/0xOptimus/status/1981001344145322019?s=20>
-
