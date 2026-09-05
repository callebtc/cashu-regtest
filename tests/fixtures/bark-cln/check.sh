#!/bin/sh
set -eu
export PATH="/fixtures:$PATH"
/bin/sh /entrypoint.sh &
entry=$!
trap 'kill "$entry" 2>/dev/null || true' EXIT
wait_for_file() {
  for attempt in $(seq 1 100); do
    [ ! -f "$1" ] || return 0
    kill -0 "$entry" 2>/dev/null || { wait "$entry"; return 1; }
    sleep 0.1
  done
  echo "Timed out waiting for $1" >&2
  return 1
}
case "$SCENARIO" in
  startup)
    wait_for_file /test-state/final-started
    read bootstrap < /test-state/bootstrap-pid
    if kill -0 "$bootstrap" 2>/dev/null; then
      echo "Bootstrap CLN survived restart" >&2
      exit 1
    fi
    kill "$entry"
    wait "$entry"
    ;;
  term)
    wait_for_file /test-state/booted
    kill "$entry"
    code=0
    wait "$entry" || code=$?
    [ "$code" -eq 143 ]
    [ ! -e /root/.lightning/regtest/tls-ready ]
    [ ! -e /test-state/final-started ]
    [ ! -d /test-state/lock ]
    read bootstrap < /test-state/bootstrap-pid
    if kill -0 "$bootstrap" 2>/dev/null; then
      echo "Bootstrap CLN survived entrypoint termination" >&2
      exit 1
    fi
    ;;
  early-exit)
    code=0
    wait "$entry" || code=$?
    [ "$code" -ne 0 ]
    [ ! -e /root/.lightning/regtest/tls-ready ]
    [ ! -e /test-state/final-started ]
    ;;
esac
trap - EXIT
echo "PASS: Bark CLN $SCENARIO lifecycle"
