#!/bin/bash

cast interface AsyncSwapCSMM --json | sed -e '1s/^/export const AsyncSwapCSMMAbi = /' -e '$a\'$'\n'' as const;' > ./packages/indexer/abis/AsyncSwapCSMM.ts

cast interface Router --json | sed -e '1s/^/export const RouterAbi = /' -e '$a\'$'\n'' as const;' > ./packages/indexer/abis/Router.ts
