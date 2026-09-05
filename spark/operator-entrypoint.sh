#!/bin/sh
set -e

index="${1:?Usage: operator-entrypoint.sh <operator-index>}"
socket_path="/tmp/frost_${index}.sock"

atlas migrate apply \
  --dir "file:///opt/spark/migrations" \
  --url "postgresql://postgres@spark-postgres:5432/sparkoperator_${index}?sslmode=disable"
atlas migrate apply \
  --dir "file:///opt/spark/ephemeral_migrations" \
  --url "postgresql://postgres@spark-postgres:5432/spark_ephemeral_${index}?sslmode=disable"

spark-frost-signer -u "$socket_path" &
signer_pid=$!

for attempt in $(seq 1 30); do
  if [ -S "$socket_path" ]; then
    break
  fi
  if ! kill -0 "$signer_pid" 2>/dev/null; then
    echo "Spark FROST signer ${index} exited before creating its socket" >&2
    exit 1
  fi
  sleep 1
done

if [ ! -S "$socket_path" ]; then
  echo "Timed out waiting for Spark FROST signer ${index}" >&2
  exit 1
fi

exec spark-operator \
  -config /opt/spark/operator.config.yaml \
  -index "$index" \
  -key "/opt/spark/keys/operator_${index}.key" \
  -operators /opt/spark/config.json \
  -threshold 2 \
  -signer "unix://${socket_path}" \
  -port 8535 \
  -database "postgresql://postgres@spark-postgres:5432/sparkoperator_${index}?sslmode=disable" \
  -ephemeral-database "postgresql://postgres@spark-postgres:5432/spark_ephemeral_${index}?sslmode=disable" \
  -server-cert "/opt/spark/tls/server_${index}.crt" \
  -server-key "/opt/spark/tls/server_${index}.key" \
  -local true
