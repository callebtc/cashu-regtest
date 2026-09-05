#!/bin/bash

# All waits are bounded and check actual state, not just RPC availability.
wait-for-ldk-height(){
  local target attempt ready i
  target=$(bitcoin-cli-sim getblockcount) || return 1
  for attempt in $(seq 1 120); do
    ready=true
    [ "$(ldk-cli-sim get-node-info 2>/dev/null | jq -r '.current_best_block.height')" = "$target" ] || ready=false
    for i in 1 2 3; do
      [ "$(lncli-sim "$i" getinfo 2>/dev/null | jq -r '.block_height')" = "$target" ] || ready=false
      [ "$(lightning-cli-sim "$i" getinfo 2>/dev/null | jq -r '.blockheight')" = "$target" ] || ready=false
    done
    [ "$ready" = true ] && return 0
    sleep 2
  done
  echo "Timed out waiting for all seven Lightning nodes at height $target" >&2
  return 1
}

wait-for-ldk-wallet-spend(){
  local before=$1 amount=$2 attempt balance
  for attempt in $(seq 1 120); do
    balance=$(ldk-cli-sim get-balances | jq -er '.total_onchain_balance_sats') || return 1
    [ "$balance" -le "$((before - amount))" ] && return 0
    sleep 1
  done
  echo 'LDK wallet funding sync timed out' >&2
  return 1
}

cashu-ldk-init(){
  local attempt address i peer node_id host channels txid ready balance before
  for attempt in $(seq 1 120); do
    if ldk-cli-sim get-node-info 2>/dev/null | jq -e '.network == "REGTEST"' >/dev/null; then break; fi
    sleep 2
  done
  ldk-cli-sim get-node-info | jq -e '.network == "REGTEST"' >/dev/null || return 1
  # Separate confirmed UTXOs allow six funding transactions without depending
  # on spending unconfirmed change. The remainder is the anchor fee reserve.
  for i in 1 2 3 4 5 6; do
    address=$(ldk-cli-sim onchain-receive | jq -er '.address') || return 1
    bitcoin-cli-sim -named sendtoaddress address="$address" amount=0.3 fee_rate=100 >/dev/null || return 1
  done
  bitcoin-cli-sim -generate 3 >/dev/null || return 1
  for attempt in $(seq 1 120); do
    balance=$(ldk-cli-sim get-balances | jq -r '.spendable_onchain_balance_sats // 0')
    [ "$balance" -ge 180000000 ] && break
    sleep 2
  done
  [ "$balance" -ge 180000000 ] || { echo 'LDK funding timed out' >&2; return 1; }

  for peer in lnd cln; do
    for i in 1 2 3; do
      if [ "$peer" = lnd ]; then
        node_id=$(lncli-sim "$i" getinfo | jq -er '.identity_pubkey') || return 1
        host="lnd-$i"
      else
        node_id=$(lightning-cli-sim "$i" getinfo | jq -er '.id') || return 1
        host="clightning-$i"
      fi
      echo "Opening balanced 24,000,000-sat LDK -> $peer-$i channel"
      before=$(ldk-cli-sim get-balances | jq -er '.total_onchain_balance_sats') || return 1
      ldk-cli-sim open-channel "$node_id" "$host:9735" 24000000sat \
        --push-to-counterparty 12000000sat --announce-channel >/dev/null || return 1
      # open-channel returns before broadcast: don't mine until the funding
      # transaction is actually in Bitcoin Core's mempool.
      ready=false
      for attempt in $(seq 1 120); do
        txid=$(ldk-cli-sim list-channels | jq -r --arg id "$node_id" \
          '.channels[]? | select(.counterparty_node_id == $id) | .funding_txo.txid // empty')
        if [ -n "$txid" ] && bitcoin-cli-sim getmempoolentry "$txid" >/dev/null 2>&1; then
          ready=true
          break
        fi
        sleep 1
      done
      [ "$ready" = true ] || { echo "LDK channel funding timed out: $peer-$i" >&2; return 1; }
      # This pinned LDK Node updates its BDK wallet asynchronously. Broadcast
      # alone does not mark the selected inputs spent in the wallet yet.
      wait-for-ldk-wallet-spend "$before" 24000000 || return 1
    done
  done
  bitcoin-cli-sim -generate 6 >/dev/null || return 1
  wait-for-ldk-height || return 1
  for attempt in $(seq 1 120); do
    channels=$(ldk-cli-sim list-channels) || return 1
    if printf '%s' "$channels" | jq -e '
      (.channels | length == 6) and
      ([.channels[].counterparty_node_id] | unique | length == 6) and
      all(.channels[]; .is_channel_ready and .is_usable and .is_outbound and .is_announced
        and .channel_value_sats == 24000000
        and .outbound_capacity_msat > 11000000000 and .inbound_capacity_msat > 11000000000)' >/dev/null; then
      echo 'PASS: LDK has six public, active, balanced outbound channels'
      return 0
    fi
    sleep 2
  done
  echo 'LDK channel readiness timed out' >&2
  return 1
}
