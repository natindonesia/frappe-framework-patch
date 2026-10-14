#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# =============================================================================
# vanilla-test-nginx.sh - smoke test the vanilla (single-app) Frappe image.
#
# Bundle filenames are unhashed (frappe esbuild entryNames "[dir]/[name]", see
# patches/0007-drop-assets-json-manifest.patch), so there is no assets.json
# manifest any more: the logical asset path frappe links to IS the path on disk.
# Cache-busting is FRAPPE_BUILD_VERSION + revalidation, not content hashes.
# This asserts exactly that: manifest gone, unhashed bundles serving 200.
# =============================================================================
docker run --rm frappe:latest bash -c '
  set -e
  /usr/local/bin/nginx-entrypoint.sh & pid=$!
  trap "kill $pid 2>/dev/null || true" EXIT
  for i in $(seq 1 20); do
    curl -sf http://127.0.0.1:8080/assets/frappe/dist/js/desk.bundle.js >/dev/null && break
    sleep 1
  done

  # The manifest must be gone from disk ...
  test ! -e sites/assets/assets.json
  # ... and 404 over HTTP (nginx `try_files $uri =404`).
  MANIFEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/assets/assets.json)
  test "$MANIFEST_CODE" = 404

  # Unhashed bundle + static paths must serve 200.
  for path in \
    /assets/frappe/dist/js/desk.bundle.js \
    /assets/frappe/dist/css/desk.bundle.css \
    /assets/frappe/dist/css/login.bundle.css \
    /assets/frappe/dist/css/print.bundle.css \
    /assets/frappe/css/frappe.css \
    /assets/frappe/node_modules/ace-builds/src-min-noconflict/ace.js ; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080$path")
    test "$CODE" = 200 || { echo "Unexpected $path -> HTTP $CODE"; exit 1; }
    echo "  ok $path (HTTP $CODE)"
  done

  SERVER_HDR=$(curl -sI http://127.0.0.1:8080/assets/frappe/dist/css/desk.bundle.css | tr -d "\r" | awk -F": " "tolower(\$1)==\"server\" {print \$2; exit}")
  case "$SERVER_HDR" in nginx*) ;; *) echo "Unexpected Server header: $SERVER_HDR"; exit 1 ;; esac

  # Unhashed filenames must revalidate instead of being cached immutably.
  CC=$(curl -sI http://127.0.0.1:8080/assets/frappe/dist/css/desk.bundle.css | tr -d "\r" | awk -F": " "tolower(\$1)==\"cache-control\" {print \$2; exit}")
  case "$CC" in *no-cache*) ;; *) echo "Unexpected Cache-Control: $CC"; exit 1 ;; esac

  echo "Nginx served unhashed bundles, no assets.json (manifest=$MANIFEST_CODE, cache-control=$CC)"
'
