#!/bin/bash
spark_enabled="false"
bark_enabled="false"
arkade_enabled="false"
export COMPOSE_PROFILES=""
for arg in "$@"; do
case "$arg" in
  --spark)
    spark_enabled="true"
    export COMPOSE_PROFILES="${COMPOSE_PROFILES:+$COMPOSE_PROFILES,}spark"
    ;;
  --bark)
    bark_enabled="true"
    export COMPOSE_PROFILES="${COMPOSE_PROFILES:+$COMPOSE_PROFILES,}bark"
    ;;
  --arkade)
    arkade_enabled="true"
    export COMPOSE_PROFILES="${COMPOSE_PROFILES:+$COMPOSE_PROFILES,}arkade"
    ;;
  *)
    echo "usage: $0 [--spark] [--bark] [--arkade]" >&2
    exit 2
    ;;
esac
done
export CASHU_SPARK_REGTEST="$spark_enabled"
export CASHU_BARK_REGTEST="$bark_enabled"

print_success() {
  printf "\033[;1;32mPASSED\033[;0m $1\n"
}

print_error() {
  printf "\033[;1;31mFAILED\033[;0m $1\n"
}

run(){
  label=$1
  value=$2
  cmd=$3
  if [[ "$cmd" == "$value" ]]; then
    print_success "$label is $cmd"
  else
    print_error "$label is $cmd, should be $value"
    failed="true"
  fi
}

failed="false"
blockheight=219
utxos=3
channel_size=24000000 # 0.024 btc
balance_size=12000000 # 0.012 btc

source docker-scripts.sh

optional_failure_logs(){
  status=$?
  if [ "$status" -ne 0 ]; then
    fee-diagnostics >&2 || true
    docker compose logs --tail=150 ldk bitcoind lnd-1 lnd-2 lnd-3 \
      clightning-1 clightning-2 clightning-3 >&2 || true
  fi
  if [ "$status" -ne 0 ] && [ "$arkade_enabled" = "true" ]; then
    docker compose --profile "*" ps -a >&2 || true
    docker compose --profile "*" logs --tail=150 arkade-operator arkade-operator-wallet arkade-fulmine arkade-boltz-backend arkade-nbxplorer bitcoind lnd-2 >&2 || true
  fi
  if [ "$status" -ne 0 ] && [ "$spark_enabled" = "true" ]; then
    docker compose ps -a >&2 || true
    docker compose logs --tail=250 \
      bitcoind clightning-1 clightning-2 clightning-3 \
      spark-postgres spark-operator-0 spark-operator-1 spark-operator-2 \
      ldk spark-ssp spark-electrs >&2 || true
  fi
  if [ "$status" -ne 0 ] && [ "$bark_enabled" = "true" ]; then
    docker compose ps -a >&2 || true
    docker compose logs --tail=250 bark-server bark-cln bark-postgres bitcoind lnd-1 >&2 || true
  fi
  exit "$status"
}
trap optional_failure_logs EXIT

cashu-regtest-start || exit 1
if [ "$spark_enabled" = "true" ]; then
  cashu-lightning-sync || exit 1
  blockheight=222
fi
if [ "$bark_enabled" = "true" ]; then
  cashu-lightning-sync || exit 1
  blockheight=$((blockheight + BARK_BLOCKS_MINED))
fi
echo "=================================="
printf "\033[;1;36mregtest started! starting tests...\033[;0m\n"
echo "=================================="
echo ""

for i in 1 2 3; do
  run "lnd-$i .synced_to_chain" "true" $(lncli-sim $i getinfo | jq -r ".synced_to_chain")
  run "lnd-$i utxo count" $utxos $(lncli-sim $i listunspent | jq -r ".utxos | length")
  run "lnd-$i .block_height" $blockheight $(lncli-sim $i getinfo | jq -r ".block_height")
  if [[ "$i" == "1" ]]; then
    channel_count=7
    if [ "$bark_enabled" = "true" ]; then
      channel_count=$((channel_count + 1))
    fi
  elif [[ "$i" == "3" ]]; then
    channel_count=4
  else 
    channel_count=3
  fi
  run "lnd-$i openchannels" $channel_count $(lncli-sim $i listchannels | jq -r ".channels | length")
  run "lnd-$i .channels[0].capacity" $channel_size $(lncli-sim $i listchannels | jq -r ".channels[0].capacity")
  run "lnd-$i .channels[0].push_amount_sat" $balance_size $(lncli-sim $i listchannels | jq -r ".channels[0].push_amount_sat")
done
for i in 1 2 3; do
  # run "cln-$i blockheight" $blockheight $(lightning-cli-sim $i getinfo | jq -r ".blockheight")
  run "cln-$i utxo count" $utxos $(lightning-cli-sim $i listfunds | jq -r ".outputs | length")
  run "cln-$i openchannels" 3 $(lightning-cli-sim $i getinfo | jq -r ".num_active_channels")
  run "cln-$i channel[0].state" "CHANNELD_NORMAL" $(lightning-cli-sim $i listfunds | jq -r ".channels[0].state")
  run "cln-$i channel[0].amount_msat" $(($channel_size * 1000)) $(lightning-cli-sim $i listfunds | jq -r ".channels[0].amount_msat" | sed 's/msat//g')
  run "cln-$i channel[0].our_amount_msat" $(($balance_size * 1000)) $(lightning-cli-sim $i listfunds | jq -r ".channels[0].our_amount_msat" | sed 's/msat//g')
done

run "lnbits service status" "200" $(curl -s -L -o /dev/null -w "%{http_code}" "http://localhost:5001/")

if [ "$spark_enabled" = "true" ]; then
  run "open-ssp service status" "200" $(curl -s -L -o /dev/null -w "%{http_code}" "http://127.0.0.1:5000/health")
  run "open-ssp Lightning mode" "live" $(curl --fail --silent \
    -H "Authorization: Bearer $SPARK_ADMIN_TOKEN" \
    http://127.0.0.1:5000/status | jq -r '.ldk_mode')
fi
run "LDK ready channels" "6" $(ldk-cli-sim list-channels | jq -r '[.channels[]? | select(.is_channel_ready == true)] | length')

# return non-zero exit code if a test fails
if [ "$failed" = "false" ] && [ "$spark_enabled" = "true" ]; then
  cashu-spark-e2e || exit 1
fi
if [ "$failed" = "false" ]; then
  bash ldk/e2e.sh || exit 1
  bash fees/e2e.sh || exit 1
fi
if [ "$failed" = "false" ] && [ "$bark_enabled" = "true" ]; then
  cashu-bark-e2e || exit 1
fi
if [ "$failed" = "false" ] && [ "$arkade_enabled" = "true" ]; then
  docker compose --profile arkade-test run --rm --build --no-deps arkade-test regtest/setup.mjs || exit 1
  # Start Lightning swaps only after their wallets are initialized and funded.
  docker compose --profile arkade --profile arkade-late up -d arkade-boltz || exit 1
  docker compose --profile arkade-test run --rm --no-deps arkade-test regtest/e2e.mjs || exit 1
fi
if [[ "$failed" == "true" ]]; then
  echo ""
  echo "=================================="
  print_error "one more more tests failed"
  echo "=================================="
  exit 1
else
  echo ""
  echo "=================================="
  print_success "all tests passed! yay!"
  echo "=================================="
fi

# # LNbits create a wallet
docker exec cashu-lnbits-1 /app/.venv/bin/python tools/create_fake_admin.py

# LNbits first install setup to disable first-install redirect
curl -s -X PUT "http://localhost:5001/api/v1/auth/first_install" \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "supersecurepassword123", "password_repeat": "supersecurepassword123"}' > /dev/null
