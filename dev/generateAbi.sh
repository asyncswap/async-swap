#!/bin/bash

cast interface AsyncSwap --json | sed -e '1s/^/export const AsyncSwapAbi = /' -e '$a\'$'\n'' as const;' > ./packages/indexer/abis/AsyncSwap.ts

cast interface Router --json | sed -e '1s/^/export const RouterAbi = /' -e '$a\'$'\n'' as const;' > ./packages/indexer/abis/Router.ts
