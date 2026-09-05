#!/bin/sh
export COMPOSE_PROJECT_NAME=cashu

SPARK_ADMIN_TOKEN=regtest-spark-admin-token

bitcoin-cli-sim() {
  docker exec cashu-bitcoind-1 bitcoin-cli -rpcuser=cashu -rpcpassword=cashu -regtest "$@"
}

# args(i, cmd)
lightning-cli-sim() {
  i=$1
  shift # shift first argument so we can use $@
  docker exec cashu-clightning-$i-1 lightning-cli --network regtest "$@"
}

# args(i, cmd)
lncli-sim() {
  i=$1
  shift # shift first argument so we can use $@
  docker exec cashu-lnd-$i-1 lncli --network regtest --rpcserver=lnd-$i:10009 "$@"
}

ldk-cli-sim() {
  container=$(docker compose --profile spark ps -q spark-ldk)
  if [ -z "$container" ]; then
    echo "spark-ldk is not running" >&2
    return 1
  fi
  api_key=$(docker exec "$container" sh -c "od -A n -t x1 /data/regtest/api_key | tr -d ' \\n'")
  docker exec "$container" ldk-server-cli \
    --base-url localhost:3536 \
    --api-key "$api_key" \
    --tls-cert /data/tls.crt \
    "$@"
}

# args(i)
fund_clightning_node() {
  address=$(lightning-cli-sim $1 newaddr | jq -r .bech32)
  echo "funding: $address on clightning-node: $1"
  bitcoin-cli-sim -named sendtoaddress address=$address amount=30 fee_rate=100 > /dev/null
}

# args(i)
fund_lnd_node() {
  address=$(lncli-sim $1 newaddress p2wkh | jq -r .address)
  echo "funding: $address on lnd-node: $1"
  bitcoin-cli-sim -named sendtoaddress address=$address amount=30 fee_rate=100 > /dev/null
}

# args(i, j)
connect_clightning_node() {
  pubkey=$(lightning-cli-sim $2 getinfo | jq -r '.id')
  lightning-cli-sim $1 connect $pubkey@cashu-clightning-$2-1:9735 | jq -r '.id'
}

# args(i)
clightning_create_rune() {
  lightning-cli-sim $1 createrune | jq -r '.rune' > ./data/clightning-$1/rune
}

cashu-regtest-start(){
  if ! command -v jq &> /dev/null
  then
      echo "jq is not installed"
      exit
  fi
  if ! command -v docker &> /dev/null
  then
      echo "docker is not installed"
      exit
  fi
  if ! command -v docker version &> /dev/null
  then
      echo "dockerd is not running"
      exit
  fi
  cashu-regtest-stop || return 1
  docker compose up -d --remove-orphans || return 1
  cashu-regtest-init
}

cashu-regtest-start-log(){
  cashu-regtest-stop || return 1
  docker compose up --remove-orphans || return 1
  cashu-regtest-init
}

cashu-regtest-stop(){
  docker compose --profile spark --profile spark-test down --volumes
  # clean up lightning node data
  docker run --rm -v "$(pwd)/data:/data" alpine rm -rf /data/clightning-1 /data/clightning-2 /data/clightning-3 /data/lnd-1 /data/lnd-2 /data/lnd-3 /data/boltz/boltz.db
  # recreate lightning node data folders preventing permission errors
  mkdir -p ./data/clightning-1 ./data/clightning-2 ./data/clightning-3 ./data/lnd-1 ./data/lnd-2 ./data/lnd-3
}

cashu-regtest-restart(){
  cashu-regtest-stop
  cashu-regtest-start
}

cashu-bitcoin-init(){
  echo "init_bitcoin_wallet..."
  local wallet_ready=false
  for i in $(seq 1 10); do
    if bitcoin-cli-sim createwallet cashu; then
      wallet_ready=true
      break
    fi
    sleep 1
  done
  if [ "$wallet_ready" != true ]; then
    echo "failed to initialize the Bitcoin wallet" >&2
    return 1
  fi
  echo "mining 150 blocks..."
  bitcoin-cli-sim -generate 150 > /dev/null
}

cashu-regtest-init(){
  cashu-bitcoin-init || return 1
  cashu-lightning-sync || return 1
  cashu-lightning-init || return 1
  if [ "${CASHU_SPARK_REGTEST:-false}" = "true" ]; then
    cashu-spark-init
  fi
}

cashu-spark-init(){
  wait-for-spark-keyshares || return 1
  wait-for-spark-ssp || return 1
  wait-for-spark-electrs || return 1
  cashu-spark-lightning-init || return 1
  cashu-spark-fund-ssp || return 1
}

wait-for-spark-keyshares(){
  echo "waiting for Spark signing keyshares..."
  for attempt in $(seq 1 120); do
    ready=true
    for i in 0 1 2; do
      count=$(docker compose exec -T spark-postgres psql \
        -U postgres -d "sparkoperator_$i" -tAc \
        "SELECT count(*) FROM signing_keyshares WHERE status = 'AVAILABLE';" \
        2>/dev/null | tr -d '[:space:]')
      case "$count" in
        ''|*[!0-9]*|0) ready=false ;;
      esac
    done
    if [ "$ready" = "true" ]; then
      echo "Spark signing keyshares are ready"
      return
    fi
    sleep 5
  done
  echo "timed out waiting for Spark signing keyshares" >&2
  return 1
}

wait-for-spark-ssp(){
  echo "waiting for open-ssp..."
  for attempt in $(seq 1 120); do
    if curl --fail --silent --max-time 5 http://127.0.0.1:5000/health > /dev/null; then
      status=$(curl --fail --silent --max-time 15 \
        -H "Authorization: Bearer $SPARK_ADMIN_TOKEN" \
        http://127.0.0.1:5000/status 2>/dev/null) || status=""
      public_identity=$(curl --fail --silent --max-time 5 \
        http://127.0.0.1:5000/identity 2>/dev/null | jq -r '.identityPublicKey // empty')
      status_identity=$(printf '%s' "$status" | jq -r '.ssp_identity_pubkey // empty' 2>/dev/null)
      wallet_identity=$(printf '%s' "$status" | jq -r '.spark.identity_pubkey // empty' 2>/dev/null)
      ldk_mode=$(printf '%s' "$status" | jq -r '.ldk_mode // empty' 2>/dev/null)
      spark_error=$(printf '%s' "$status" | jq -r '.spark_error // empty' 2>/dev/null)
      if [ "$ldk_mode" = "live" ] \
        && [ -n "$public_identity" ] \
        && [ "$public_identity" = "$status_identity" ] \
        && [ "$public_identity" = "$wallet_identity" ] \
        && [ -z "$spark_error" ]; then
        echo "open-ssp is live with identity $public_identity"
        return
      fi
    fi
    sleep 5
  done
  echo "timed out waiting for a live open-ssp" >&2
  return 1
}

wait-for-spark-electrs(){
  echo "waiting for Spark Esplora..."
  for attempt in $(seq 1 120); do
    if curl --fail --silent --max-time 5 \
      http://127.0.0.1:30000/blocks/tip/height > /dev/null; then
      echo "Spark Esplora is ready"
      return
    fi
    sleep 2
  done
  echo "timed out waiting for Spark Esplora" >&2
  return 1
}

cashu-spark-lightning-init(){
  ldk_address=$(ldk-cli-sim onchain-receive | jq -er '.address') || return 1
  echo "funding Spark ldk-server on-chain reserve"
  bitcoin-cli-sim -named sendtoaddress \
    address="$ldk_address" amount=0.001 fee_rate=100 > /dev/null || return 1
  bitcoin-cli-sim -generate 3 > /dev/null

  for attempt in $(seq 1 60); do
    spendable=$(ldk-cli-sim get-balances | jq -r '.spendable_onchain_balance_sats // 0')
    if [ "$spendable" -ge 25000 ]; then
      break
    fi
    sleep 2
  done
  if [ "$spendable" -lt 25000 ]; then
    echo "timed out funding the Spark ldk-server on-chain reserve" >&2
    return 1
  fi

  ldk_node_id=$(ldk-cli-sim get-node-info | jq -r '.node_id')
  if [ -z "$ldk_node_id" ] || [ "$ldk_node_id" = "null" ]; then
    echo "ldk-server did not return a node ID" >&2
    return 1
  fi

  lncli-sim 1 connect "$ldk_node_id@spark-ldk:9735" > /dev/null
  echo "open channel from lnd-1 to Spark ldk-server"
  lncli-sim 1 openchannel "$ldk_node_id" 24000000 12000000 > /dev/null
  bitcoin-cli-sim -generate 6 > /dev/null
  wait-for-lnd-channel 1

  for attempt in $(seq 1 60); do
    ready=$(ldk-cli-sim list-channels | jq -r \
      --arg node_id "$(lncli-sim 1 getinfo | jq -r '.identity_pubkey')" \
      '[.channels[]? | select(.counterparty_node_id == $node_id and .is_channel_ready == true)] | length')
    if [ "$ready" -gt 0 ]; then
      echo "Spark ldk-server channel is ready"
      return
    fi
    sleep 2
  done
  echo "timed out waiting for the Spark ldk-server channel" >&2
  return 1
}

cashu-spark-fund-ssp(){
  deposit_file=$(mktemp)
  for amount_sats in 1000 1000 1000 2000 2000 2000 4000 4000 4000 8000 8000 8000; do
    address=$(curl --fail --silent --max-time 30 -X POST \
      -H "Authorization: Bearer $SPARK_ADMIN_TOKEN" \
      http://127.0.0.1:5000/admin/spark/deposit-address | jq -er '.address') || {
        rm -f "$deposit_file"
        return 1
      }
    amount_btc=$(awk -v sats="$amount_sats" 'BEGIN { printf "%.8f", sats / 100000000 }')
    txid=$(bitcoin-cli-sim -named sendtoaddress \
      address="$address" amount="$amount_btc" fee_rate=100)
    printf '%s %s\n' "$txid" "$address" >> "$deposit_file"
  done

  bitcoin-cli-sim -generate 3 > /dev/null
  sleep 4

  while read -r txid address; do
    transaction_json=$(bitcoin-cli-sim getrawtransaction "$txid" true)
    transaction_hex=$(bitcoin-cli-sim getrawtransaction "$txid" false)
    vout=$(printf '%s' "$transaction_json" | jq -er --arg address "$address" \
      '.vout[] | select(.scriptPubKey.address == $address or ((.scriptPubKey.addresses // []) | any(. == $address))) | .n')
    body=$(jq -nc --arg transaction_hex "$transaction_hex" --argjson vout "$vout" \
      '{transaction_hex: $transaction_hex, vout: $vout}')
    curl --fail --silent --max-time 60 -X POST \
      -H "Authorization: Bearer $SPARK_ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$body" \
      http://127.0.0.1:5000/admin/spark/claim-deposit > /dev/null || {
        rm -f "$deposit_file"
        return 1
      }
  done < "$deposit_file"
  rm -f "$deposit_file"

  available=$(curl --fail --silent --max-time 15 \
    -H "Authorization: Bearer $SPARK_ADMIN_TOKEN" \
    http://127.0.0.1:5000/status | jq -r '.spark.available_sats // 0')
  if [ "$available" -le 0 ]; then
    echo "open-ssp has no available Spark liquidity after funding" >&2
    return 1
  fi
  echo "funded open-ssp with $available sats of Spark liquidity"
}

cashu-spark-e2e(){
  e2e_output_file=$(mktemp)
  if ! docker compose --profile spark --profile spark-test run --rm --build --no-deps spark-test \
    > "$e2e_output_file"; then
    cat "$e2e_output_file"
    rm -f "$e2e_output_file"
    return 1
  fi
  cat "$e2e_output_file"
  e2e_result=$(grep '^{"status":"PASS"' "$e2e_output_file" | tail -n 1)
  rm -f "$e2e_output_file"
  if [ -z "$e2e_result" ]; then
    echo "Spark SDK test did not emit a PASS result" >&2
    return 1
  fi

  send_hash=$(printf '%s' "$e2e_result" | jq -er '.sendPaymentHash') || return 1
  send_preimage=$(printf '%s' "$e2e_result" | jq -er '.sendPaymentPreimage') || return 1
  receive_hash=$(printf '%s' "$e2e_result" | jq -er '.receivePaymentHash') || return 1

  payments=$(ldk-cli-sim list-payments)
  outbound=$(printf '%s' "$payments" | jq \
    --arg hash "$send_hash" --arg preimage "$send_preimage" \
    '[.list[]? | select(
      .direction == "OUTBOUND"
      and .status == "SUCCEEDED"
      and .amount_msat == 3000000
      and .kind.kind.bolt11.hash == $hash
      and .kind.kind.bolt11.preimage == $preimage
    )] | length')
  inbound=$(printf '%s' "$payments" | jq \
    --arg hash "$receive_hash" \
    '[.list[]? | select(
      .direction == "INBOUND"
      and .status == "SUCCEEDED"
      and .amount_msat == 5000000
      and .kind.kind.bolt11.hash == $hash
    )] | length')
  if [ "$outbound" -ne 1 ] || [ "$inbound" -ne 1 ]; then
    echo "ldk-server payment records do not match the SDK/LND settlements" >&2
    return 1
  fi

  for i in 0 1 2; do
    unsettled=$(docker compose exec -T spark-postgres psql \
      -U postgres -d "sparkoperator_$i" -tAc \
      "SELECT count(*) FROM transfers WHERE type IN ('PRIMARY_SWAP_V3', 'COUNTER_SWAP_V3') AND status <> 'COMPLETED';" \
      | tr -d '[:space:]')
    if [ "$unsettled" -ne 0 ]; then
      echo "Spark operator $i has $unsettled unsettled swap transfers" >&2
      return 1
    fi
  done
}

cashu-lightning-sync(){
  wait-for-clightning-sync 1 || return 1
  wait-for-clightning-sync 2 || return 1
  wait-for-clightning-sync 3 || return 1
  wait-for-lnd-sync 1 || return 1
  wait-for-lnd-sync 2 || return 1
  wait-for-lnd-sync 3 || return 1
}

cashu-lightning-init(){

  # create 10 UTXOs for each node
  for i in 0 1 2; do
    fund_clightning_node 1
    fund_clightning_node 2
    fund_clightning_node 3
    fund_lnd_node 1
    fund_lnd_node 2
    fund_lnd_node 3
  done

  echo "mining 3 blocks..."
  bitcoin-cli-sim -generate 3 > /dev/null

  cashu-lightning-sync

  channel_confirms=6
  channel_size=24000000 # 0.024 btc
  balance_size=12000000 # 0.12 btc
  balance_size_msat=12000000000 # 0.12 btc

  # lnd-1 -> lnd-2
  lncli-sim 1 connect $(lncli-sim 2 getinfo | jq -r '.identity_pubkey')@cashu-lnd-2-1 > /dev/null
  echo "open channel from lnd-1 to lnd-2"
  lncli-sim 1 openchannel $(lncli-sim 2 getinfo | jq -r '.identity_pubkey') $channel_size $balance_size > /dev/null
  bitcoin-cli-sim -generate $channel_confirms > /dev/null
  wait-for-lnd-channel 1

  # lnd-1 -> lnd-3
  lncli-sim 1 connect $(lncli-sim 3 getinfo | jq -r '.identity_pubkey')@cashu-lnd-3-1 > /dev/null
  echo "open channel from lnd-1 to lnd-3"
  lncli-sim 1 openchannel $(lncli-sim 3 getinfo | jq -r '.identity_pubkey') $channel_size $balance_size > /dev/null
  bitcoin-cli-sim -generate $channel_confirms > /dev/null
  wait-for-lnd-channel 1

  # lnd-1 -> cln-1
  lncli-sim 1 connect $(lightning-cli-sim 1 getinfo | jq -r '.id')@cashu-clightning-1-1 > /dev/null
  echo "open channel from lnd-1 to cln-1"
  lncli-sim 1 openchannel $(lightning-cli-sim 1 getinfo | jq -r '.id') $channel_size $balance_size > /dev/null
  bitcoin-cli-sim -generate $channel_confirms > /dev/null
  wait-for-lnd-channel 1

  # lnd-1 -> cln-2
  lncli-sim 1 connect $(lightning-cli-sim 2 getinfo | jq -r '.id')@cashu-clightning-2-1 > /dev/null
  echo "open channel from lnd-1 to cln-2"
  lncli-sim 1 openchannel $(lightning-cli-sim 2 getinfo | jq -r '.id') $channel_size $balance_size > /dev/null
  bitcoin-cli-sim -generate $channel_confirms > /dev/null
  wait-for-lnd-channel 1

  # lnd-1 -> cln-3
  lncli-sim 1 connect $(lightning-cli-sim 3 getinfo | jq -r '.id')@cashu-clightning-3-1 > /dev/null
  echo "open channel from lnd-1 to cln-3"
  lncli-sim 1 openchannel $(lightning-cli-sim 3 getinfo | jq -r '.id') $channel_size $balance_size > /dev/null
  bitcoin-cli-sim -generate $channel_confirms > /dev/null
  wait-for-lnd-channel 1

  # lnd-2 -> cln-2
  lncli-sim 2 connect $(lightning-cli-sim 2 getinfo | jq -r '.id')@cashu-clightning-2-1 > /dev/null
  echo "open channel from lnd-2 to cln-2"
  lncli-sim 2 openchannel $(lightning-cli-sim 2 getinfo | jq -r '.id') $channel_size $balance_size > /dev/null
  bitcoin-cli-sim -generate $channel_confirms > /dev/null
  wait-for-lnd-channel 2

  # lnd-3 -> cln-3
  lncli-sim 3 connect $(lightning-cli-sim 3 getinfo | jq -r '.id')@cashu-clightning-3-1 > /dev/null
  echo "open channel from lnd-3 to cln-1"
  lncli-sim 3 openchannel $(lightning-cli-sim 3 getinfo | jq -r '.id') $channel_size $balance_size > /dev/null
  bitcoin-cli-sim -generate $channel_confirms > /dev/null
  wait-for-lnd-channel 3

  # lnd-3 -> cln-1
  lncli-sim 3 connect $(lightning-cli-sim 1 getinfo | jq -r '.id')@cashu-clightning-1-1 > /dev/null
  echo "open channel from lnd-3 to cln-1"
  lncli-sim 3 openchannel $(lightning-cli-sim 1 getinfo | jq -r '.id') $channel_size $balance_size > /dev/null
  bitcoin-cli-sim -generate $channel_confirms > /dev/null
  wait-for-lnd-channel 3

  wait-for-clightning-channel 1
  wait-for-clightning-channel 2
  wait-for-clightning-channel 3

  # create rune for each clightning node
  clightning_create_rune 1
  clightning_create_rune 2
  clightning_create_rune 3

  cashu-lightning-sync

}

wait-for-lnd-channel(){
  while true; do
    pending=$(lncli-sim $1 pendingchannels | jq -r '.pending_open_channels | length')
    echo "lnd-$1 pendingchannels: $pending"
    if [[ "$pending" == "0" ]]; then
      break
    fi
    sleep 1
  done
}

wait-for-lnd-sync(){
  while true; do
    if [[ "$(lncli-sim $1 getinfo 2>&1 | jq -r '.synced_to_chain' 2> /dev/null)" == "true" ]]; then
      echo "lnd-$1 is synced!"
      break
    fi
    echo "waiting for lnd-$1 to sync..."
    sleep 1
  done
}

wait-for-clightning-channel(){
  while true; do
    pending=$(lightning-cli-sim $1 getinfo | jq -r '.num_pending_channels | length')
    echo "cln-$1 pendingchannels: $pending"
    if [[ "$pending" == "0" ]]; then
      if [[ "$(lightning-cli-sim $1 getinfo 2>&1 | jq -r '.warning_bitcoind_sync' 2> /dev/null)" == "null" ]]; then
        if [[ "$(lightning-cli-sim $1 getinfo 2>&1 | jq -r '.warning_lightningd_sync' 2> /dev/null)" == "null" ]]; then
          break
        fi
      fi
    fi
    sleep 1
  done
}

wait-for-clightning-sync(){
  local attempt info
  for attempt in $(seq 1 180); do
    if info=$(lightning-cli-sim "$1" getinfo 2>&1) && \
      printf '%s' "$info" | jq -e \
        '(.id | type == "string" and length > 0) and
         .warning_bitcoind_sync == null and .warning_lightningd_sync == null' > /dev/null 2>&1; then
      echo "cln-$1 is synced!"
      return 0
    fi
    echo "waiting for cln-$1 to sync..."
    sleep 1
  done
  echo "timed out waiting for cln-$1 to sync; last getinfo response: $info" >&2
  docker compose logs --tail=100 bitcoind "clightning-$1" >&2 || true
  return 1
}
