#!/bin/bash
# Exercise failure propagation without Docker or resetting regtest data.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./docker-scripts.sh
cashu-fees-init() { :; }

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

(
  export CASHU_SPARK_REGTEST=true CASHU_BARK_REGTEST=true
  cashu-bitcoin-init() { :; }
  cashu-lightning-sync() { :; }
  cashu-lightning-init() { :; }
  cashu-spark-init() { return 1; }
  cashu-ldk-init() { :; }
  cashu-bark-init() { echo 'ERROR: continued after Spark failure' >&2; exit 99; }
  if cashu-regtest-init; then exit 1; fi
)
(
  export CASHU_SPARK_REGTEST=false CASHU_BARK_REGTEST=true
  cashu-bitcoin-init() { :; }
  cashu-lightning-sync() { :; }
  cashu-lightning-init() { :; }
  cashu-bark-init() { return 1; }
  cashu-ldk-init() { :; }
  if cashu-regtest-init; then exit 1; fi
)
if bash ./start.sh --invalid-option >/dev/null 2>&1; then
  echo 'ERROR: unknown startup option accepted' >&2
  exit 1
fi
echo 'Optional profile startup regression tests passed'

(
  bitcoin-cli-sim() { :; }
  cashu-lightning-sync() { :; }
  wait-for-bark-lightning-height() { :; }
  captaind-cli-sim() { echo '{"rounds":{"address":"test-address"}}'; }
  bark-lightning-cli-sim() { echo '{"id":"bark-node"}'; }
  lncli-sim() {
    if [ "$2" = listchannels ]; then
      echo '{"channels":[{"remote_pubkey":"bark-node","active":true,"capacity":"24000000","push_amount_sat":"12000000","local_balance":"11996530","remote_balance":"12000000"}]}'
    fi
  }
  lightning-cli-sim() { echo '{"id":"cln-node","route":[]}'; }
  sleep() { :; }
  if cashu-bark-init >/dev/null 2>&1; then
    echo 'ERROR: active channel without a gossip route was treated as ready' >&2
    exit 1
  fi
)
echo 'Bark gossip readiness regression test passed'

(
  bitcoin-cli-sim() { echo 216; }
  lightning-cli-sim() { echo '{"blockheight":210}'; }
  lncli-sim() { echo '{"block_height":216}'; }
  bark-lightning-cli-sim() { echo '{"blockheight":216}'; }
  sleep() { :; }
  if wait-for-bark-lightning-height >/dev/null 2>&1; then
    echo 'ERROR: stale CLN height was treated as synchronized' >&2
    exit 1
  fi
)
echo 'Bark Lightning height regression test passed'

(
  docker() {
    case " $* " in
      *" -rpcwallet=cashu "*) return 0 ;;
      *) echo 'ERROR: Bitcoin helper did not select the faucet wallet' >&2; return 1 ;;
    esac
  }
  bitcoin-cli-sim getnewaddress
)
echo 'Multi-wallet Bitcoin helper regression test passed'

(
  cashu-bitcoin-init() { :; }
  cashu-lightning-sync() { :; }
  cashu-lightning-init() { :; }
  cashu-ldk-init() { return 1; }
  export CASHU_SPARK_REGTEST=true
  cashu-spark-init() { echo 'ERROR: continued after LDK failure' >&2; exit 99; }
  if cashu-regtest-init; then exit 1; fi
)
(
  bitcoin-cli-sim() { echo 210; }
  ldk-cli-sim() { echo '{"current_best_block":{"height":209}}'; }
  lncli-sim() { echo '{"block_height":210}'; }
  lightning-cli-sim() { echo '{"blockheight":210}'; }
  sleep() { :; }
  if wait-for-ldk-height >/dev/null 2>&1; then
    echo 'ERROR: stale LDK height was treated as synchronized' >&2
    exit 1
  fi
)
echo 'LDK startup failure and chain-height regression tests passed'
(
  sleep() { :; }
  ldk-cli-sim() { echo '{"total_onchain_balance_sats":180000000}'; }
  if wait-for-ldk-wallet-spend 180000000 24000000 >/dev/null 2>&1; then
    echo 'ERROR: reused wallet inputs before the funding spend was observed' >&2
    exit 1
  fi
  ldk-cli-sim() { echo '{"total_onchain_balance_sats":155990000}'; }
  wait-for-ldk-wallet-spend 180000000 24000000
)
echo 'LDK channel-funding wallet sync regression test passed'

(
  # Model a wallet which never sees unconfirmed funding transactions. Each
  # spend must be mined before the next channel can select wallet inputs.
  height=201 opened=0 confirmed=0
  sleep() { :; }
  bitcoin-cli-sim() {
    case "$1" in
      -generate)
        height=$((height + $2))
        confirmed=$opened ;;
      getblockcount) echo "$height" ;;
      getmempoolentry|-named) echo '{}' ;;
      *) return 1 ;;
    esac
  }
  ldk-cli-sim() {
    case "$1" in
      get-node-info) printf '{"network":"REGTEST","current_best_block":{"height":%s}}\n' "$height" ;;
      onchain-receive) echo '{"address":"funding-address"}' ;;
      get-balances)
        printf '{"spendable_onchain_balance_sats":%s,"total_onchain_balance_sats":%s}\n' \
          "$((180000000 - confirmed * 24001000))" "$((180000000 - confirmed * 24001000))" ;;
      open-channel)
        [ "$opened" = "$confirmed" ] || { echo 'ERROR: reused unconfirmed wallet inputs' >&2; return 1; }
        opened=$((opened + 1)) ;;
      list-channels)
        jq -n --argjson count "$opened" '{channels:[range($count) |
          {counterparty_node_id:((if . < 3 then "lnd-" else "cln-" end) + (. % 3 + 1 | tostring)),
           funding_txo:{txid:"funding-tx"}, is_channel_ready:true, is_usable:true,
           is_outbound:true, is_announced:true, channel_value_sats:24000000,
           outbound_capacity_msat:12000000000, inbound_capacity_msat:12000000000}]}' ;;
      *) return 1 ;;
    esac
  }
  lncli-sim() { printf '{"identity_pubkey":"lnd-%s","block_height":%s}\n' "$1" "$height"; }
  lightning-cli-sim() { printf '{"id":"cln-%s","blockheight":%s}\n' "$1" "$height"; }
  cashu-ldk-init >/dev/null
  [ "$opened" = 6 ] && [ "$confirmed" = 6 ] && [ "$height" = 215 ]
)
echo 'LDK funding confirmation regression passed without mempool wallet updates'

(
  cashu-bitcoin-init() { :; }
  cashu-lightning-sync() { :; }
  cashu-lightning-init() { :; }
  cashu-ldk-init() { :; }
  cashu-fees-init() { return 1; }
  export CASHU_SPARK_REGTEST=true
  cashu-spark-init() { echo 'ERROR: continued after fee topology failure' >&2; exit 99; }
  if cashu-regtest-init; then exit 1; fi
)
(
  fee-hub-cli-sim() { echo '{"block_height":219}'; }
  lncli-sim() { echo '{"block_height":219}'; }
  lightning-cli-sim() { echo '{"blockheight":219}'; }
  ldk-fee-cli-sim() { echo '{"current_best_block":{"height":218}}'; }
  if fee-height-ready 219; then
    echo 'ERROR: stale fee leaf accepted' >&2; exit 1
  fi
)
(
  fee-hub-cli-sim() {
    if [ "$1" = getinfo ]; then echo '{"identity_pubkey":"hub"}'; else
      echo '{"channels":[{"scid":"1"},{"scid":"2"},{"scid":"3"},{"scid":"4"}]}'
    fi
  }
  lightning-cli-sim() { echo '{"channels":[]}'; }
  lncli-sim() { echo '{"node1_pub":"hub","node1_policy":{"disabled":false,"fee_base_msat":"1000","fee_rate_milli_msat":"0"}}'; }
  ldk-fee-cli-sim() { echo '{"channel":null}'; }
  if fee-policies-ready >/dev/null 2>&1; then
    echo 'ERROR: stale zero-fee graph accepted' >&2; exit 1
  fi
)
echo 'Fee topology failure, stale height, and stale policy regressions passed'

(
  for policy in '' 'null' '{}' \
    '{"enabled":false,"base_msat":1000,"ppm":1000}' \
    '{"enabled":true,"base_msat":1000,"ppm":0}' \
    '{"enabled":true,"base_msat":1000,"ppm":1000,"inbound_ppm":-1000}'; do
    if fee-policy-ready test-leaf 123 "$policy" >/dev/null 2>&1; then
      echo "ERROR: invalid fee policy accepted: $policy" >&2; exit 1
    fi
  done
  fee-policy-ready test-leaf 123 '{"enabled":true,"base_msat":"1000","ppm":"1000"}'
)
echo 'Missing, disabled, and stale fee policy regression tests passed'

(
  sleep() { :; }
  fee-channels-ready() { [ "$scenario" != inactive ]; }
  fee-leaves-isolated() { :; }
  fee-policies-ready() {
    polls=$((polls + 1))
    [ "$scenario" = healthy ] || { [ "$scenario" != stuck ] && [ "$reconnects" = 1 ]; }
  }
  fee-reconnect-leaves() { reconnects=$((reconnects + 1)); }
  for scenario in healthy recovered stuck inactive; do
    polls=0 reconnects=0
    if wait-for-fee-policies >/dev/null 2>&1; then
      [ "$scenario" = healthy ] || [ "$scenario" = recovered ]
    else
      [ "$scenario" = stuck ] || [ "$scenario" = inactive ]
    fi
    case "$scenario" in
      healthy) [ "$polls" = 1 ] && [ "$reconnects" = 0 ] ;;
      recovered) [ "$polls" = 61 ] && [ "$reconnects" = 1 ] ;;
      *) [ "$polls" = 120 ] && [ "$reconnects" = 1 ] ;;
    esac
  done
)
echo 'Fee gossip recovery is bounded and still requires ready policies and channels'

(
  fee-node-id() { echo "$1"; }
  sleep() { connected=false; }
  fee-hub-cli-sim() {
    case "$1" in
      disconnect) current_peer=$2; connected=true ;;
      listpeers)
        jq -n --arg peer "$current_peer" --argjson connected "$connected" \
          '{peers:(if $connected then [{pub_key:$peer}] else [] end)}' ;;
      connect)
        connects=$((connects + 1))
        connected=true
        case "$scenario" in
          remote-reconnected) return 1 ;;
          failed) connected=false; return 1 ;;
        esac ;;
    esac
  }
  for scenario in normal remote-reconnected failed; do
    connects=0
    if fee-reconnect-leaves >/dev/null 2>&1; then
      [ "$scenario" != failed ] && [ "$connects" = 3 ]
    else
      [ "$scenario" = failed ] && [ "$connects" = 1 ]
    fi
  done
)
echo 'Fee reconnect waits for disconnect and verifies competing remote connections'

(
  export CASHU_SPARK_REGTEST=true
  bitcoin-cli-sim() {
    case "$*" in
      'createwallet cashu') return 0 ;;
      'createwallet ssp-withdrawals') return 1 ;;
      *) echo 'ERROR: continued after withdrawal wallet failure' >&2; exit 99 ;;
    esac
  }
  if cashu-bitcoin-init; then exit 1; fi
)
echo 'Spark withdrawal wallet initialization failure regression passed'

(
  # Fail closed if independent backend evidence is absent or disagrees with Breez.
  fixture=$(jq -nc '{status:"PASS", settlements:
    ["lnd","cln"] | map(. as $peer | ["INBOUND","OUTBOUND"] | map(
      {peer:$peer,direction:.,sats:(if . == "INBOUND" then 5000 else 3000 end),
       hash:($peer + .),preimage:"fixture-preimage"})) | flatten}')
  docker() {
    case " $* " in
      *' run '*) printf '%s\n' "$fixture" ;;
      *' exec '*)
        case "$scenario" in
          db-failure) return 1 ;;
          incomplete|settling) echo 1 ;;
          empty-db-response) : ;;
          *) echo 0 ;;
        esac ;;
      *) return 1 ;;
    esac
  }
  ldk-cli-sim() {
    if [ "$scenario" = ldk-failure ]; then return 1; fi
    printf '%s' "$fixture" | jq --arg scenario "$scenario" '{list: [.settlements[] |
      {direction, status:(if $scenario == "unsettled" then "PENDING" else "SUCCEEDED" end),
       amount_msat:(.sats * 1000), kind:{kind:{bolt11:{hash,preimage}}}}]}'
  }
  sleep() { if [ "$scenario" = settling ]; then scenario=clean; fi; }
  for scenario in clean settling db-failure incomplete empty-db-response ldk-failure unsettled; do
    if cashu-spark-e2e >/dev/null 2>&1; then
      [ "$scenario" = clean ] || { echo "ERROR: accepted Spark $scenario" >&2; exit 1; }
    else
      [ "$scenario" != clean ] || { echo 'ERROR: rejected valid Spark settlements' >&2; exit 1; }
    fi
  done
)
echo 'Breez backend settlement and operator-query failure regressions passed'
