#!/bin/bash
# Exercise failure propagation without Docker or resetting regtest data.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./docker-scripts.sh

(
  cashu-regtest-stop() { return 0; }
  docker() { return 23; }
  cashu-regtest-init() { echo 'ERROR: initialized after Compose failure' >&2; exit 99; }
  if cashu-regtest-start; then
    echo 'ERROR: Compose failure was ignored' >&2
    exit 1
  fi
)

(
  cashu-bitcoin-init() { return 1; }
  cashu-lightning-sync() { echo 'ERROR: waited after Bitcoin failure' >&2; exit 99; }
  if cashu-regtest-init; then exit 1; fi
)

(
  bitcoin-cli-sim() { return 1; }
  sleep() { :; }
  if cashu-bitcoin-init >/dev/null 2>&1; then
    echo 'ERROR: wallet initialization failure was ignored' >&2
    exit 1
  fi
)

(
  wait-for-clightning-sync() { return 1; }
  wait-for-lnd-sync() { echo 'ERROR: continued after CLN failure' >&2; exit 99; }
  if cashu-lightning-sync; then exit 1; fi
)

(
  lightning-cli-sim() { echo 'No such container' >&2; return 1; }
  sleep() { :; }
  docker() { :; }
  if wait-for-clightning-sync 1 >/dev/null 2>&1; then
    echo 'ERROR: failed RPC was treated as synced' >&2
    exit 1
  fi
)

(
  lightning-cli-sim() { echo '{"id":"test-node"}'; }
  wait-for-clightning-sync 1
)
echo 'Startup regression tests passed'
