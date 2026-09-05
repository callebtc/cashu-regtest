#!/bin/bash
# Disposable regtest only. No mnemonic is emitted by these helpers.
bark-cli-sim() {
  docker compose --profile bark exec -T bark-wallet timeout 180 bark --datadir /wallets/test "$@"
}

captaind-cli-sim() {
  docker compose --profile bark exec -T bark-server timeout 60 captaind --config /etc/bark/captaind.toml rpc "$@"
}

bark-lightning-cli-sim() {
  docker compose --profile bark exec -T bark-cln lightning-cli --regtest "$@"
}

bark-mine() {
  bitcoin-cli-sim -generate "$1" >/dev/null || return 1
  BARK_BLOCKS_MINED=$((BARK_BLOCKS_MINED + $1))
}

wait-for-bark-lightning-height() {
  local tip attempt index ready
  tip=$(bitcoin-cli-sim getblockcount) || return 1
  for attempt in $(seq 1 120); do
    ready=true
    for index in 1 2 3; do
      [ "$(lightning-cli-sim "$index" getinfo | jq -r '.blockheight')" = "$tip" ] || ready=false
      [ "$(lncli-sim "$index" getinfo | jq -r '.block_height')" = "$tip" ] || ready=false
    done
    [ "$(bark-lightning-cli-sim getinfo | jq -r '.blockheight')" = "$tip" ] || ready=false
    [ "$ready" = true ] && return 0
    sleep 1
  done
  echo "Lightning nodes did not reach Bitcoin height $tip" >&2
  return 1
}

cashu-bark-init() {
  local node address attempt cln_node
  BARK_BLOCKS_MINED=0
  node=$(bark-lightning-cli-sim getinfo | jq -er '.id') || return 1
  address=$(captaind-cli-sim wallet | jq -er '.rounds.address') || return 1
  bitcoin-cli-sim -named sendtoaddress address="$address" amount=10 fee_rate=10 >/dev/null || return 1
  bark-mine 3 || return 1
  cashu-lightning-sync || return 1
  lncli-sim 1 connect "$node@bark-cln:9735" >/dev/null || return 1
  lncli-sim 1 openchannel "$node" 24000000 12000000 >/dev/null || return 1
  bark-mine 6 || return 1
  wait-for-bark-lightning-height || return 1
  cln_node=$(lightning-cli-sim 1 getinfo | jq -er '.id') || return 1
  echo 'Waiting for Bark channel activation and bidirectional CLN gossip routes...'
  for attempt in $(seq 1 120); do
    if lncli-sim 1 listchannels | jq -e --arg node "$node" \
      '.channels[] | select(.remote_pubkey == $node and .active and .capacity == "24000000" and .push_amount_sat == "12000000" and (.local_balance | tonumber) > 11900000 and (.remote_balance | tonumber) == 12000000)' >/dev/null; then
      # Active is not enough: distant CLN nodes may not know the new node yet.
      if lightning-cli-sim 1 getroute "$node" 5000000 1 2>/dev/null | jq -e '.route | length > 0' >/dev/null && \
        bark-lightning-cli-sim getroute "$cln_node" 3000000 1 2>/dev/null | jq -e '.route | length > 0' >/dev/null; then
        return 0
      fi
    fi
    sleep 1
  done
  echo 'Bark Lightning channel/routes did not become ready' >&2
  return 1
}

cashu-bark-e2e() {
  echo 'Testing a fresh Bark wallet: onchain receive, board, send, Lightning send/receive'
  bash ./bark/e2e.sh || return 1
  # The acceptance test mines three confirmations for funding, board, and offboard.
  BARK_BLOCKS_MINED=$((BARK_BLOCKS_MINED + 9))
}
