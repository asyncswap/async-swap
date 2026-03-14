#!/usr/bin/env bash
set -euo pipefail

TOKEN_A="${TOKEN0_ADDRESS:?Missing TOKEN0_ADDRESS}"
TOKEN_B="${TOKEN1_ADDRESS:?Missing TOKEN1_ADDRESS}"
TICK_SPACING="${TICK_SPACING:-240}"

if [[ -n "${ASYNCSWAP_ADDRESS:-}" ]]; then
  HOOK="$ASYNCSWAP_ADDRESS"
else
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  case "${CHAIN:-anvil}" in
    anvil) CHAIN_ID="31337" ;;
    unichain-sepolia) CHAIN_ID="1301" ;;
    unichain) CHAIN_ID="130" ;;
    mainnet) CHAIN_ID="1" ;;
    optimism) CHAIN_ID="10" ;;
    base) CHAIN_ID="8453" ;;
    arbitrum-one) CHAIN_ID="42161" ;;
    polygon) CHAIN_ID="137" ;;
    blast) CHAIN_ID="81457" ;;
    zora) CHAIN_ID="7777777" ;;
    worldchain) CHAIN_ID="480" ;;
    ink) CHAIN_ID="57073" ;;
    soneium) CHAIN_ID="1868" ;;
    avalanche) CHAIN_ID="43114" ;;
    bnb-smart-chain) CHAIN_ID="56" ;;
    celo) CHAIN_ID="42220" ;;
    monad) CHAIN_ID="143" ;;
    megaeth) CHAIN_ID="4326" ;;
    sepolia) CHAIN_ID="11155111" ;;
    base-sepolia) CHAIN_ID="84532" ;;
    arbitrum-sepolia) CHAIN_ID="421614" ;;
    *) echo "Unsupported CHAIN=${CHAIN:-}" >&2; exit 1 ;;
  esac
  if [[ "${RUN_MODE:-broadcast}" == "dry-run" ]]; then
    JSON_PATH="$ROOT_DIR/broadcast/00_DeployAsyncSwap.s.sol/$CHAIN_ID/dry-run/run-latest.json"
  else
    JSON_PATH="$ROOT_DIR/broadcast/00_DeployAsyncSwap.s.sol/$CHAIN_ID/run-latest.json"
  fi
  HOOK="$(python3 - <<PY
import json
from pathlib import Path
data = json.loads(Path('$JSON_PATH').read_text())
print(data['transactions'][1]['contractAddress'])
PY
)"
fi

SORTED="$(python3 - <<PY "$TOKEN_A" "$TOKEN_B"
import sys
a = int(sys.argv[1], 16)
b = int(sys.argv[2], 16)
if a < b:
    print(sys.argv[1], sys.argv[2])
else:
    print(sys.argv[2], sys.argv[1])
PY
)"

C0="$(printf '%s' "$SORTED" | awk '{print $1}')"
C1="$(printf '%s' "$SORTED" | awk '{print $2}')"

ENCODED="$(cast abi-encode "f(address,address,uint24,int24,address)" "$C0" "$C1" 8388608 "$TICK_SPACING" "$HOOK")"
cast keccak "$ENCODED"
