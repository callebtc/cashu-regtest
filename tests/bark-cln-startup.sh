#!/bin/bash
# Exercise the real entrypoint in its actual /bin/sh without touching regtest.
set -euo pipefail
cd "$(dirname "$0")/.."
image=$(docker compose --profile bark config --format json | jq -r '.services["bark-cln"].image')
for scenario in startup term early-exit; do
  docker run --rm --network none \
    --tmpfs /root/.lightning --tmpfs /test-state \
    -v "$PWD/bark/cln-entrypoint.sh:/entrypoint.sh:ro" \
    -v "$PWD/tests/fixtures/bark-cln:/fixtures:ro" \
    -e "SCENARIO=$scenario" --entrypoint timeout "$image" \
    20 /bin/sh /fixtures/check.sh
done
