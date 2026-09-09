#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

docker run --rm frappe:latest bash -c '
  /usr/local/bin/nginx-entrypoint.sh & pid=$!
  trap "kill $pid 2>/dev/null || true" EXIT
  for i in $(seq 1 20); do
    curl -sf http://127.0.0.1:8080/assets/assets.json >/dev/null && break
    sleep 1
  done
  test -s sites/assets/assets.json
  HTTP_CODE=$(curl -s -o /tmp/served-assets.json -w "%{http_code}" http://127.0.0.1:8080/assets/assets.json)
  test "$HTTP_CODE" = 200
  SERVER_HDR=$(curl -sI http://127.0.0.1:8080/assets/assets.json | tr -d "\r" | awk -F": " "tolower(\$1)==\"server\" {print \$2; exit}")
  case "$SERVER_HDR" in nginx*) ;; *) echo "Unexpected Server header: $SERVER_HDR"; exit 1 ;; esac
  cmp -s sites/assets/assets.json /tmp/served-assets.json
  ASSET_PATH=$(jq -er ".\"desk.bundle.js\"" /tmp/served-assets.json)
  ASSET_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080$ASSET_PATH")
  test "$ASSET_CODE" = 200
  ACE_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/assets/frappe/node_modules/ace-builds/src-min-noconflict/ace.js)
  test "$ACE_CODE" = 200
  echo "Nginx served assets.json and manifest assets (assets.json=$HTTP_CODE, desk=$ASSET_CODE, ace=$ACE_CODE)"
'