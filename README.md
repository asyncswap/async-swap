# Async Swap AMM

- [AsyncCSMM - hook contract](src/AsyncSwap.sol)
- [Router - add liquidity, swap & fill async orders](src/router.sol)
- [Live Demo Frontend](https://frontend-mu-one-27.vercel.app/)
- [Video Walkthrough](https://www.loom.com/share/b66cfb28f41b452c8cb6debceea35631?sid=962ac2ae-c2d4-49ff-b621-b99428b44ff9)
- [Transaction Ordering rules walkthorugh video](https://www.loom.com/share/15839f36efaf42e48642b5f1269c6709?sid=ab37fb1b-a31a-4519-9973-d34a7777360f)

## Install

To install dependencies in all our packages in `packages/*`

```bash
bun install
```

Install foundry dependencies (v4-periphery)

```sh
forge install
```

## Setup

> [!TIP]
> We suggest you set up local anvil account with cast.
>
> ```sh
> cast wallet import --mnemonic "test test test test test test test test test test test junk" anvil
> ```
>
> - This will allow you to use `--account anvil` in the deploys scripts in [`.dev/start_script.sh`](./dev/start_script.sh)

Run local anvil node with Unichain fork

```sh
anvil --fork-url https://unichain.drpc.org
# or simulate block mining and finality
anvil --block-time 13
```

## Local Deployment

Run deployment script

```sh
./dev/start_script.sh # scripts that you use --account setup of you choice
```

> [!NOTE]
>
> The start scripts will do the following:
>
> 1. Deploy local PoolManger [`./script/00_DeployPoolManager.s.sol`](./script/00_DeployPoolManager.s.sol)
> 2. Deploy Hook & Router contracts [`./script/01_DeployHook.s.sol`](./script/01_DeployHook.s.sol)
> 3. Initialize a pool with your hook attached [`./script/02_InitilizePool.s.sol`](./script/02_InitilizePool.s.sol)
> 4. Add liqudity to previously initialized pool [`./script/03_AddLiquidity.s.sol`](./script/03_AddLiquidity.s.sol)
> 5. Submit an async swap transaction through custom router [`./script/04_Swap.s.sol`](./script/04_Swap.s.sol)
> 6. Fill previously submitted swap transaction [`./script/05_ExecuteOrder.s.sol`](./script/05_ExecuteOrder.s.sol)

## Testing

Run tests

```sh
forge test -vvvv
```

Huff tests:

```sh
# sender is poolManager address
hnc src/AsyncSwap.huff test --sender 0x0000000000000000000000000000000000000000
```

## Offchain Indexer

Start local indexer

```sh
bun run dev
```

> [!Tip]
>
> - If you need typescript abi for your contracts on frontend or indexer use this script [`./dev/generateAbi.sh`](./dev/generateAbi.sh)
>
> ```sh
> ./dev/generateAbi.sh
> ```

Go to [http://localhost:42069](http://localhost:42069) to query orders from hook events

## Docs

View documentation:

```sh
forge doc --serve --port 4000 --watch

```

## Acknowledgment

Thanks to [Atrium Academy](https://atrium.academy), over the past 2 months we build this project during Uniswap Hook incubator program.

Team Socials:

- Meek [X](https://x.com/msakiart), [github](https://github.com/mmsaki)
- Jiasun Li [X](https://x.com/mysteryfigure), [github](https://github.com/mysteryfigure)
