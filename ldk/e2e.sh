#!/bin/bash
set -Eeuo pipefail
trap 'echo "LDK acceptance failed at line $LINENO" >&2' ERR
cd "$(dirname "$0")/.."
source ./docker-scripts.sh
for command in jq xxd openssl; do
  command -v "$command" >/dev/null || { echo "Missing test dependency: $command" >&2; exit 1; }
done
assert_json() { jq -e "$@" >/dev/null; }
hash_preimage() { printf '%s' "$1" | xxd -r -p | openssl dgst -sha256 | awk '{print $NF}'; }
wait_payment() {
  local hash=$1 direction=$2 amount=$3 attempt payment
  for attempt in $(seq 1 60); do
    payment=$(ldk-cli-sim list-payments --number-of-payments 1000 | jq -c --arg hash "$hash" \
      '[.list[]? | select(.kind.kind.bolt11.hash == $hash)] | first')
    if printf '%s' "$payment" | jq -e --arg direction "$direction" --argjson amount "$amount" \
      '.status == "SUCCEEDED" and .direction == $direction and .amount_msat == $amount' >/dev/null; then
      printf '%s' "$payment"
      return 0
    fi
    if printf '%s' "$payment" | jq -e '.status == "FAILED"' >/dev/null; then break; fi
    sleep 2
  done
  echo "LDK payment did not settle: $hash ($direction)" >&2
  return 1
}

wait-for-ldk-height
ldk_id=$(ldk-cli-sim get-node-info | jq -er '.node_id')
for peer in lnd cln; do
  for i in 1 2 3; do
    label="ldk-$peer-$i-$(date +%s)"
    # Both ends must agree this is an active, balanced direct channel.
    if [ "$peer" = lnd ]; then
      lncli-sim "$i" listchannels | assert_json --arg id "$ldk_id" \
        'any(.channels[]; .remote_pubkey == $id and .active and .capacity == "24000000"
          and (.local_balance | tonumber) > 11000000 and (.remote_balance | tonumber) > 11000000)'
      invoice=$(lncli-sim "$i" addinvoice --amt 3000 | jq -er '.payment_request')
    else
      lightning-cli-sim "$i" listfunds | assert_json --arg id "$ldk_id" \
        'any(.channels[]; .peer_id == $id and .state == "CHANNELD_NORMAL"
          and .amount_msat == 24000000000 and .our_amount_msat > 11000000000)'
      invoice=$(lightning-cli-sim "$i" invoice 3000000 "$label" 'LDK acceptance' | jq -er '.bolt11')
    fi
    hash=$(ldk-cli-sim decode-invoice "$invoice" | jq -er '.payment_hash')
    ldk-cli-sim bolt11-send "$invoice" >/dev/null
    payment=$(wait_payment "$hash" OUTBOUND 3000000)
    preimage=$(printf '%s' "$payment" | jq -er '.kind.kind.bolt11.preimage')
    [ "$(hash_preimage "$preimage")" = "$hash" ]
    if [ "$peer" = lnd ]; then
      settled=$(lncli-sim "$i" lookupinvoice "$hash")
      printf '%s' "$settled" | assert_json '.state == "SETTLED" and .amt_paid_sat == "3000"'
      printf '%s' "$settled" | assert_json --arg preimage "$preimage" '.r_preimage == $preimage'
    else
      lightning-cli-sim "$i" listinvoices "$label" | assert_json --arg hash "$hash" --arg preimage "$preimage" \
        'any(.invoices[]; .status == "paid" and .amount_received_msat == 3000000
          and .payment_hash == $hash and .payment_preimage == $preimage)'
    fi
    echo "PASS: LDK -> $peer-$i settled 3,000 sats with matching hash/preimage"

    received=$(ldk-cli-sim bolt11-receive 5000sat --description "$label")
    invoice=$(printf '%s' "$received" | jq -er '.invoice')
    hash=$(printf '%s' "$received" | jq -er '.payment_hash')
    if [ "$peer" = lnd ]; then
      result=$(lncli-sim "$i" payinvoice --force --json --timeout 120s "$invoice")
      printf '%s' "$result" | assert_json --arg hash "$hash" \
        '.status == "SUCCEEDED" and .payment_hash == $hash and .value_sat == "5000"'
      preimage=$(printf '%s' "$result" | jq -er '.payment_preimage')
    else
      result=$(docker exec "cashu-clightning-$i-1" timeout 150 lightning-cli --network regtest -N none \
        -k pay bolt11="$invoice" retry_for=120)
      printf '%s' "$result" | assert_json --arg hash "$hash" \
        '.status == "complete" and .payment_hash == $hash and .amount_msat == 5000000'
      preimage=$(printf '%s' "$result" | jq -er '.payment_preimage')
    fi
    [ "$(hash_preimage "$preimage")" = "$hash" ]
    payment=$(wait_payment "$hash" INBOUND 5000000)
    printf '%s' "$payment" | assert_json --arg preimage "$preimage" '.kind.kind.bolt11.preimage == $preimage'
    echo "PASS: $peer-$i -> LDK settled 5,000 sats with matching hash/preimage"
  done
done
echo 'PASS: all 12 LDK Lightning payments settled'
