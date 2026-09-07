#!/bin/bash

fee-hub-cli-sim(){
  docker exec cashu-fee-hub-1 lncli --network regtest --rpcserver=fee-hub:10009 "$@"
}
ldk-fee-cli-sim(){
  local key
  key=$(docker exec cashu-ldk-fee-1 sh -c "od -A n -t x1 /data/regtest/api_key | tr -d ' \\n'") || return 1
  docker exec cashu-ldk-fee-1 ldk-server-cli --base-url localhost:3536 --api-key "$key" --tls-cert /data/tls.crt "$@"
}
fee-node-id(){
  case "$1" in
    lnd) lncli-sim 4 getinfo | jq -er '.identity_pubkey';;
    cln) lightning-cli-sim 4 getinfo | jq -er '.id';;
    ldk) ldk-fee-cli-sim get-node-info | jq -er '.node_id';;
    bridge) lncli-sim 1 getinfo | jq -er '.identity_pubkey';;
  esac
}
fee-wait(){
  local attempt
  for attempt in $(seq 1 120); do
    if "$@"; then return 0; fi
    sleep 2
  done
  echo "Timed out: $*" >&2
  return 1
}
fee-height-ready(){
  local height=$1
  [ "$(fee-hub-cli-sim getinfo 2>/dev/null | jq -r '.block_height')" = "$height" ] &&
  [ "$(lncli-sim 4 getinfo 2>/dev/null | jq -r '.block_height')" = "$height" ] &&
  [ "$(lightning-cli-sim 4 getinfo 2>/dev/null | jq -r '.blockheight')" = "$height" ] &&
  [ "$(ldk-fee-cli-sim get-node-info 2>/dev/null | jq -r '.current_best_block.height')" = "$height" ]
}
fee-channels-ready(){
  fee-hub-cli-sim listchannels | jq -e '
    (.channels | length == 4) and
    ([.channels[].remote_pubkey] | unique | length == 4) and
    all(.channels[]; .active and .capacity == "24000000"
      and (.local_balance | tonumber) > 11000000 and (.remote_balance | tonumber) > 11000000)' >/dev/null
}
fee-leaves-isolated(){
  local hub
  hub=$(fee-hub-cli-sim getinfo | jq -er '.identity_pubkey') || return 1
  lncli-sim 4 listchannels | jq -e --arg hub "$hub" \
    '(.channels | length == 1) and .channels[0].remote_pubkey == $hub and .channels[0].active' >/dev/null &&
  lightning-cli-sim 4 listpeerchannels | jq -e --arg hub "$hub" \
    '(.channels | length == 1) and .channels[0].peer_id == $hub and .channels[0].state == "CHANNELD_NORMAL"' >/dev/null &&
  ldk-fee-cli-sim list-channels | jq -e --arg hub "$hub" \
    '(.channels | length == 1) and .channels[0].counterparty_node_id == $hub and .channels[0].is_usable' >/dev/null
}
fee-policies-ready(){
  local hub channel channels cln_graph scid
  hub=$(fee-hub-cli-sim getinfo | jq -er '.identity_pubkey') || return 1
  fee-hub-cli-sim listchannels | jq -e '.channels | length == 4' >/dev/null || return 1
  # LND 0.21 exposes the wire channel ID as chan_id; graph APIs use scid.
  channels=$(fee-hub-cli-sim listchannels | jq -er '.channels[].scid') || return 1
  cln_graph=$(lightning-cli-sim 4 listchannels) || return 1
  for channel in $channels; do
    lncli-sim 4 getchaninfo "$channel" | jq -e --arg hub "$hub" '
      (if .node1_pub == $hub then .node1_policy else .node2_policy end) |
      .disabled == false and (.fee_base_msat | tonumber) == 1000
      and (.fee_rate_milli_msat | tonumber) == 1000
      and ((.inbound_fee_base_msat // 0) | tonumber) == 0
      and ((.inbound_fee_rate_milli_msat // 0) | tonumber) == 0' >/dev/null || return 1
    scid="$((channel >> 40))x$(((channel >> 16) & 16777215))x$((channel & 65535))"
    printf '%s' "$cln_graph" | jq -e --arg hub "$hub" --arg scid "$scid" '
      any(.channels[]; .source == $hub and .short_channel_id == $scid and .active
        and .base_fee_millisatoshi == 1000 and .fee_per_millionth == 1000)' >/dev/null || return 1
    ldk-fee-cli-sim graph-get-channel "$channel" | jq -e --arg hub "$hub" '
      .channel | (if .node_one == $hub then .one_to_two else .two_to_one end) |
      .enabled and .fees.base_msat == 1000 and .fees.proportional_millionths == 1000' >/dev/null || return 1
  done
}
fee-reserves-ready(){
  fee-hub-cli-sim walletbalance | jq -e '(.confirmed_balance | tonumber) >= 120000000' >/dev/null &&
  lncli-sim 4 walletbalance | jq -e '(.confirmed_balance | tonumber) >= 100000' >/dev/null &&
  lightning-cli-sim 4 listfunds | jq -e 'any(.outputs[]; .status == "confirmed" and .amount_msat >= 100000000)' >/dev/null &&
  ldk-fee-cli-sim get-balances | jq -e '.spendable_onchain_balance_sats >= 100000' >/dev/null
}
cashu-fees-init(){
  local address peer host node txid result
  fee-wait fee-height-ready "$(bitcoin-cli-sim getblockcount)" || return 1
  for peer in 1 2 3 4; do
    address=$(fee-hub-cli-sim newaddress p2wkh | jq -er '.address') || return 1
    bitcoin-cli-sim -named sendtoaddress address="$address" amount=0.3 fee_rate=100 >/dev/null || return 1
  done
  for peer in lnd cln ldk; do
    case "$peer" in
      lnd) address=$(lncli-sim 4 newaddress p2wkh | jq -er '.address');;
      cln) address=$(lightning-cli-sim 4 newaddr | jq -er '.bech32');;
      ldk) address=$(ldk-fee-cli-sim onchain-receive | jq -er '.address');;
    esac
    [ -n "$address" ] || return 1
    bitcoin-cli-sim -named sendtoaddress address="$address" amount=0.001 fee_rate=100 >/dev/null || return 1
  done
  bitcoin-cli-sim -generate 3 >/dev/null || return 1
  fee-wait fee-reserves-ready || return 1
  for peer in lnd cln ldk bridge; do
    case "$peer" in lnd) host=lnd-4;; cln) host=clightning-4;; ldk) host=ldk-fee;; bridge) host=lnd-1;; esac
    node=$(fee-node-id "$peer") || return 1
    fee-hub-cli-sim connect "$node@$host:9735" >/dev/null || return 1
    result=$(fee-hub-cli-sim openchannel --node_key "$node" --local_amt 24000000 --push_amt 12000000 \
      --base_fee_msat 1000 --fee_rate_ppm 1000 --sat_per_vbyte 10) || return 1
    txid=$(printf '%s' "$result" | jq -er '.funding_txid') || return 1
    fee-wait bitcoin-cli-sim getmempoolentry "$txid" >/dev/null || return 1
  done
  bitcoin-cli-sim -generate 6 >/dev/null || return 1
  wait-for-ldk-height || return 1
  fee-wait fee-height-ready "$(bitcoin-cli-sim getblockcount)" || return 1
  fee-wait fee-channels-ready || return 1
  fee-hub-cli-sim updatechanpolicy --base_fee_msat 1000 --fee_rate_ppm 1000 \
    --inbound_base_fee_msat 0 --inbound_fee_rate_ppm 0 --time_lock_delta 80 >/dev/null || return 1
  fee-wait fee-leaves-isolated || return 1
  fee-wait fee-policies-ready || return 1
  echo 'PASS: three isolated leaves and four balanced hub channels advertise 1 sat + 1,000 ppm'
}
fee-diagnostics(){
  docker compose logs --tail=120 fee-hub lnd-4 clightning-4 ldk-fee
  fee-hub-cli-sim listchannels
  fee-hub-cli-sim describegraph
  fee-hub-cli-sim fwdinghistory --start_time 0 --max_events 50000
}
