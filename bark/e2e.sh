#!/bin/bash
set -Eeuo pipefail
trap 'echo "Bark acceptance failed at line $LINENO" >&2' ERR
cd "$(dirname "$0")/.."
source ./docker-scripts.sh
for command in jq xxd openssl; do
  command -v "$command" >/dev/null || { echo "Missing test dependency: $command" >&2; exit 1; }
done

assert_json() { jq -e "$@" >/dev/null; }
hash_preimage() { printf '%s' "$1" | xxd -r -p | openssl dgst -sha256 | awk '{print $NF}'; }
balance() { bark-cli-sim --quiet balance | jq -er '.spendable_sat'; }

bark-cli-sim --quiet create --regtest --ark http://bark-server:3535 \
  --bitcoind http://bitcoind:18443 --bitcoind-user cashu --bitcoind-pass cashu
address=$(bark-cli-sim --quiet onchain address | jq -er '.address')
bitcoin-cli-sim -named sendtoaddress address="$address" amount=0.01 fee_rate=10 >/dev/null
bitcoin-cli-sim -generate 3 >/dev/null
bark-cli-sim --quiet onchain balance | assert_json '.confirmed_sat == 1000000'
echo 'PASS: Bark received 1,000,000 confirmed onchain sats'

# Verify both the embedded Bitcoin wallet and Ark-to-Bitcoin cooperative offboard.
destination=$(bitcoin-cli-sim getnewaddress)
txid=$(bark-cli-sim --quiet onchain send "$destination" '10000 sat' | jq -er '.txid')
bitcoin-cli-sim getrawtransaction "$txid" true | assert_json --arg addr "$destination" \
  'any(.vout[]; .scriptPubKey.address == $addr and .value == 0.0001)'
bark-cli-sim --quiet board '250000 sat' >/dev/null
bitcoin-cli-sim -generate 3 >/dev/null
# CLN can have no sync warnings while its block poll still lags Core. A stale
# payer height produces an HTLC expiry below the hold invoice's required delta.
wait-for-bark-lightning-height
bitcoin-cli-sim getrawtransaction "$txid" true | assert_json '.confirmations >= 3'
for attempt in $(seq 1 60); do
  if bark-cli-sim --quiet balance | assert_json '.spendable_sat > 240000 and .pending_board_sat == 0'; then
    break
  fi
  sleep 1
done
bark-cli-sim --quiet balance | assert_json '.spendable_sat > 240000 and .pending_board_sat == 0'
echo 'PASS: Bark sent onchain and boarded spendable Ark funds'

for peer in lnd cln; do
  if [ "$peer" = lnd ]; then
    invoice=$(lncli-sim 1 addinvoice --amt 3000 | jq -er '.payment_request')
  else
    invoice=$(lightning-cli-sim 1 invoice 3000000 bark-send 'Bark acceptance' | jq -er '.bolt11')
  fi
  before=$(balance)
  bark-cli-sim --quiet lightning pay invoice "$invoice" --wait
  status=$(bark-cli-sim --quiet lightning pay status "$invoice")
  printf '%s' "$status" | assert_json '.state == "paid" and (.preimage | length == 64)'
  hash=$(printf '%s' "$status" | jq -er '.payment_hash')
  preimage=$(printf '%s' "$status" | jq -er '.preimage')
  [ "$(hash_preimage "$preimage")" = "$hash" ]
  if [ "$peer" = lnd ]; then
    lncli-sim 1 lookupinvoice "$hash" | assert_json '.state == "SETTLED" and .amt_paid_sat == "3000"'
  else
    lightning-cli-sim 1 listinvoices bark-send | assert_json --arg preimage "$preimage" \
      '.invoices[0] | .status == "paid" and .amount_received_msat == 3000000 and .payment_preimage == $preimage'
  fi
  bark-lightning-cli-sim listpays "$invoice" | assert_json --arg hash "$hash" --arg preimage "$preimage" \
    'any(.pays[]; .status == "complete" and .payment_hash == $hash and .preimage == $preimage)'
  # Fresh boarded VTXOs use the >2,160-block fee tier: 75 + 8,000 ppm = 99 sat.
  [ "$(balance)" -eq "$((before - 3099))" ]
  echo "PASS: Bark -> $peer settled 3,000 sats, matching hash/preimage, fees enabled"
done

result_dir=$(mktemp -d)
cleanup() {
  local result=$?
  if [ "$result" -ne 0 ]; then
    for peer in lnd cln; do
      if [ -f "$result_dir/$peer.json" ]; then
        echo "$peer payer result:" >&2
        cat "$result_dir/$peer.json" >&2
      fi
    done
  fi
  if [ -n "${payer_pid:-}" ]; then
    kill "$payer_pid" 2>/dev/null || true
    wait "$payer_pid" 2>/dev/null || true
  fi
  rm -f "$result_dir/lnd.json" "$result_dir/cln.json"
  rmdir "$result_dir"
}
trap cleanup EXIT
for peer in lnd cln; do
  before=$(balance)
  invoice=$(bark-cli-sim --quiet lightning invoice '5000 sat' | jq -er '.invoice')
  if [ "$peer" = lnd ]; then
    lncli-sim 1 payinvoice --force --json --timeout 120s "$invoice" >"$result_dir/$peer.json" &
  else
    docker exec cashu-clightning-1-1 timeout 150 lightning-cli --network regtest -N none \
      -k pay bolt11="$invoice" retry_for=120 >"$result_dir/$peer.json" &
  fi
  payer_pid=$!
  bark-cli-sim --quiet lightning claim "$invoice" --wait
  wait "$payer_pid"
  payer_pid=''
  status=$(bark-cli-sim --quiet lightning receive status "$invoice")
  printf '%s' "$status" | assert_json '.state == "settled" and .amount_sat == 5000'
  hash=$(printf '%s' "$status" | jq -er '.payment_hash')
  preimage=$(printf '%s' "$status" | jq -er '.payment_preimage')
  [ "$(hash_preimage "$preimage")" = "$hash" ]
  if [ "$peer" = lnd ]; then
    assert_json --arg hash "$hash" --arg preimage "$preimage" \
      '.status == "SUCCEEDED" and .payment_hash == $hash and .payment_preimage == $preimage' <"$result_dir/$peer.json"
  else
    assert_json --arg hash "$hash" --arg preimage "$preimage" \
      '.status == "complete" and .payment_hash == $hash and .payment_preimage == $preimage' <"$result_dir/$peer.json"
  fi
  after=$(balance)
  bark-lightning-cli-sim listholdinvoices | assert_json --arg hash "$hash" --arg preimage "$preimage" \
    'any(.holdinvoices[]; .payment_hash == $hash and .preimage == $preimage and .state == "paid" and ([.htlcs[].msat] | add) == 5000000)'
  # Pinned default receive fee: 100 sat + 2,000 ppm of 5,000 sat = 110 sat.
  [ "$after" -eq "$((before + 4890))" ]
  echo "PASS: $peer -> Bark settled 5,000 sats and credited $((after - before)) sats after fees"
done

destination=$(bitcoin-cli-sim getnewaddress)
txid=$(bark-cli-sim --quiet send-onchain "$destination" '20000 sat' | jq -er '.offboard_txid')
bitcoin-cli-sim -generate 3 >/dev/null
wait-for-bark-lightning-height
bitcoin-cli-sim getrawtransaction "$txid" true | assert_json --arg addr "$destination" \
  '.confirmations >= 3 and any(.vout[]; .scriptPubKey.address == $addr and .value == 0.0002)'
bark-cli-sim --quiet balance | assert_json \
  '.spendable_sat > 0 and .pending_board_sat == 0 and .pending_lightning_send_sat == 0 and .claimable_lightning_receive_sat == 0 and .pending_in_round_sat == 0'
echo 'PASS: Ark offboard paid 20,000 confirmed sats; no pending wallet funds'
