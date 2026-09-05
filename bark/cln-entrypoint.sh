#!/bin/sh
set -eu
start_cln() {
  lightningd --network=regtest --alias=cashu-bark --large-channels \
    --bind-addr=0.0.0.0:9735 --grpc-host=0.0.0.0 --grpc-port=9736 \
    --bitcoin-rpcconnect=bitcoind --bitcoin-rpcport=18443 \
    --bitcoin-rpcuser=cashu --bitcoin-rpcpassword=cashu \
    --important-plugin=/usr/local/bin/hold \
    --hold-grpc-host=0.0.0.0 --hold-grpc-port=9988
}
if [ ! -f /root/.lightning/regtest/tls-ready ]; then
  start_cln &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true' EXIT TERM INT
  ready=false
  for attempt in $(seq 1 120); do
    kill -0 "$pid" || exit 1
    if [ -f /root/.lightning/regtest/hold/ca.pem ]; then
      ready=true
      break
    fi
    sleep 1
  done
  [ "$ready" = true ] || exit 1
  kill "$pid"
  wait "$pid" || true
  trap - EXIT TERM INT
  # Trust the generated CAs, but give both servers proper non-CA certificates
  # with container DNS names. Preserve the generated client credentials.
  for dir in /root/.lightning/regtest /root/.lightning/regtest/hold; do
    openssl req -new -newkey rsa:2048 -nodes \
      -keyout "$dir/server-key.pem" -out "$dir/server.csr" \
      -subj /CN=cln >/dev/null 2>&1
    printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
      'keyUsage=critical,digitalSignature,keyEncipherment' \
      'extendedKeyUsage=serverAuth' \
      'subjectAltName=DNS:cln,DNS:bark-cln,DNS:localhost' > "$dir/server.ext"
    openssl x509 -req -in "$dir/server.csr" -CA "$dir/ca.pem" \
      -CAkey "$dir/ca-key.pem" -CAcreateserial -days 3650 \
      -extfile "$dir/server.ext" -out "$dir/server.pem" >/dev/null 2>&1
  done
  touch /root/.lightning/regtest/tls-ready
fi
exec lightningd --network=regtest --alias=cashu-bark --large-channels \
  --bind-addr=0.0.0.0:9735 --grpc-host=0.0.0.0 --grpc-port=9736 \
  --bitcoin-rpcconnect=bitcoind --bitcoin-rpcport=18443 \
  --bitcoin-rpcuser=cashu --bitcoin-rpcpassword=cashu \
  --important-plugin=/usr/local/bin/hold \
  --hold-grpc-host=0.0.0.0 --hold-grpc-port=9988
