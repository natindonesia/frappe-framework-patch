#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

docker run --rm frappe:latest bash -c '
  export PATH=/home/frappe/.nvm/versions/node/v24.13.0/bin:$PATH
  cd /home/frappe/frappe-bench
  LOG=/tmp/socketio.log
  node apps/frappe/socketio.js >"$LOG" 2>&1 & NODE_PID=$!
  trap "kill $NODE_PID 2>/dev/null || true" EXIT
  for i in $(seq 1 30); do
    grep -q "Realtime service listening" "$LOG" && break
    sleep 1
  done
  grep -q "Realtime service listening" "$LOG" || { cat "$LOG"; exit 1; }
  echo "Socket.io service reached listening state"
'