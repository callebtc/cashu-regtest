#!/bin/bash
set -Eeuo pipefail
trap 'echo "Fee acceptance failed at line $LINENO" >&2' ERR
cd "$(dirname "$0")/.."
source ./docker-scripts.sh
assert_json(){ jq -e "$@" >/dev/null; }
fee-history(){ fee-hub-cli-sim fwdinghistory --start_time 0 --max_events 50000; }
fee-id-channel(){
  fee-hub-cli-sim listchannels | jq -er --arg id "$(fee-node-id "$1")" '.channels[] | select(.remote_pubkey == $id) | .scid'
}
fee-balance(){
  fee-hub-cli-sim listchannels | jq -er '[.channels[].local_balance | tonumber * 1000] | add'
}
fee-settled(){
  fee-hub-cli-sim listchannels | assert_json 'all(.channels[]; (.pending_htlcs | length) == 0)'
}
fee-accounted(){
  fee-settled && [ "$(fee-balance)" = "$1" ]
}
fee-invoice(){
  local peer=$1 sats=$2 label=$3
  case "$peer" in
    lnd|bridge)
      local index=4; [ "$peer" = bridge ] && index=1
      lncli-sim "$index" addinvoice --amt "$sats" | jq -er '.payment_request';;
    cln) lightning-cli-sim 4 invoice "$((sats * 1000))" "$label" 'Hub fee acceptance' | jq -er '.bolt11';;
    ldk) ldk-fee-cli-sim bolt11-receive "${sats}sat" --description "$label" | jq -er '.invoice';;
  esac
}
fee-ldk-payment(){
  ldk-fee-cli-sim list-payments --number-of-payments 1000 | jq -c --arg hash "$1" \
    '[.list[]? | select(.kind.kind.bolt11.hash == $hash)] | first'
}
fee-ldk-succeeded(){ fee-ldk-payment "$1" | assert_json '.status == "SUCCEEDED"'; }
fee-received(){
  local peer=$1 hash=$2 preimage=$3 sats=$4 label=$5
  case "$peer" in
    lnd|bridge)
      local index=4; [ "$peer" = bridge ] && index=1
      lncli-sim "$index" lookupinvoice "$hash" | assert_json --arg preimage "$preimage" --arg sats "$sats" \
        '.state == "SETTLED" and .amt_paid_sat == $sats and .r_preimage == $preimage';;
    cln) lightning-cli-sim 4 listinvoices "$label" | assert_json --arg hash "$hash" --arg preimage "$preimage" --argjson amount "$((sats * 1000))" \
      'any(.invoices[]; .status == "paid" and .payment_hash == $hash and .payment_preimage == $preimage and .amount_received_msat == $amount)';;
    ldk) fee-ldk-payment "$hash" | assert_json --arg preimage "$preimage" --argjson amount "$((sats * 1000))" \
      '.status == "SUCCEEDED" and .direction == "INBOUND" and .amount_msat == $amount and .kind.kind.bolt11.preimage == $preimage';;
  esac
}
fee-forwarded(){
  local count=$1 incoming=$2 outgoing=$3 amount=$4 fee=$5
  fee-history | assert_json --argjson count "$count" --arg incoming "$incoming" --arg outgoing "$outgoing" \
    --argjson amount "$amount" --argjson fee "$fee" '
      (.forwarding_events | length) == ($count + 1) and
      (.forwarding_events[-1] | .chan_id_in == $incoming and .chan_id_out == $outgoing
        and (.amt_in_msat | tonumber) == ($amount + $fee)
        and (.amt_out_msat | tonumber) == $amount and (.fee_msat | tonumber) == $fee)'
}
fee-payment(){
  local from=$1 to=$2 sats=$3 fee label invoice hash result preimage index before count incoming outgoing
  fee=$((1 + sats / 1000))
  label="fees-$from-$to-$sats-$(date +%s)"
  incoming=$(fee-id-channel "$from")
  outgoing=$(fee-id-channel "$to")
  fee-wait fee-settled
  before=$(fee-balance)
  count=$(fee-history | jq '.forwarding_events | length')
  invoice=$(fee-invoice "$to" "$sats" "$label")
  hash=$(ldk-fee-cli-sim decode-invoice "$invoice" | jq -er '.payment_hash')
  case "$from" in
    lnd|bridge)
      index=4; [ "$from" = bridge ] && index=1
      result=$(lncli-sim "$index" payinvoice --force --json --timeout 30s --fee_limit "$fee" "$invoice")
      printf '%s' "$result" | assert_json --arg hash "$hash" --argjson fee "$((fee * 1000))" --argjson amount "$sats" \
        '.status == "SUCCEEDED" and .payment_hash == $hash and (.fee_msat | tonumber) == $fee and (.value_sat | tonumber) == $amount'
      preimage=$(printf '%s' "$result" | jq -er '.payment_preimage');;
    cln)
      result=$(docker exec cashu-clightning-4-1 timeout 45 lightning-cli --network regtest -N none -k pay \
        bolt11="$invoice" maxfee="$((fee * 1000))" retry_for=30)
      printf '%s' "$result" | assert_json --arg hash "$hash" --argjson fee "$((fee * 1000))" --argjson amount "$((sats * 1000))" \
        '.status == "complete" and .payment_hash == $hash and .amount_msat == $amount and (.amount_sent_msat - .amount_msat) == $fee'
      preimage=$(printf '%s' "$result" | jq -er '.payment_preimage');;
    ldk)
      ldk-fee-cli-sim bolt11-send "$invoice" --max-total-routing-fee "${fee}sat" >/dev/null
      fee-wait fee-ldk-succeeded "$hash"
      result=$(fee-ldk-payment "$hash")
      printf '%s' "$result" | assert_json --argjson fee "$((fee * 1000))" --argjson amount "$((sats * 1000))" \
        '.direction == "OUTBOUND" and .fee_paid_msat == $fee and .amount_msat == $amount'
      preimage=$(printf '%s' "$result" | jq -er '.kind.kind.bolt11.preimage');;
  esac
  [ "$(printf '%s' "$preimage" | xxd -r -p | openssl dgst -sha256 | awk '{print $NF}')" = "$hash" ]
  fee-wait fee-received "$to" "$hash" "$preimage" "$sats" "$label"
  fee-wait fee-forwarded "$count" "$incoming" "$outgoing" "$((sats * 1000))" "$((fee * 1000))"
  fee-wait fee-accounted "$((before + fee * 1000))"
  echo "PASS: $from -> hub -> $to: $sats sats delivered, $fee sats routing fee; hash/preimage, forwarding and hub balance agree"
}

wait-for-ldk-height
fee-wait fee-height-ready "$(bitcoin-cli-sim getblockcount)"
fee-wait fee-leaves-isolated
fee-wait fee-policies-ready
fee-wait fee-settled
initial_balance=$(fee-balance)
initial_count=$(fee-history | jq '.forwarding_events | length')

# An insufficient fee budget must not settle or credit the hub.
label="fees-under-budget-$(date +%s)"
invoice=$(fee-invoice cln 10000 "$label")
if result=$(trap - ERR; lncli-sim 4 payinvoice --force --json --timeout 10s --fee_limit 10 "$invoice"); then
  : # Some CLI versions report a terminal FAILED payment with exit status 0.
fi
[ -n "$result" ]
printf '%s' "$result" | assert_json '.status == "FAILED" and all(.htlcs[]?; .status != "SUCCEEDED")'
lightning-cli-sim 4 listinvoices "$label" | assert_json '.invoices[0].status == "unpaid"'
fee-wait fee-settled
[ "$(fee-balance)" = "$initial_balance" ]
[ "$(fee-history | jq '.forwarding_events | length')" = "$initial_count" ]
echo 'PASS: 10-sat budget rejected an 11-sat route; invoice unpaid, no hub fee earned'

for sats in 10000 100000; do
  for from in lnd cln ldk; do
    for to in lnd cln ldk; do
      [ "$from" = "$to" ] && continue
      fee-payment "$from" "$to" "$sats"
    done
  done
done
fee-payment bridge cln 10000
fee-payment cln bridge 10000
fee-wait fee-leaves-isolated
fee-wait fee-accounted "$((initial_balance + 694000))"
[ "$(fee-history | jq '.forwarding_events | length')" -eq "$((initial_count + 14))" ]
echo 'PASS: 14 routed payments, 694 sats earned by the hub, and one rejected fee budget'
