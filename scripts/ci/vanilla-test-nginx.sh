#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# =============================================================================
# vanilla-test-nginx.sh - smoke test the vanilla (single-app) Frappe image.
#
# Bundle filenames are hashed (frappe esbuild entryNames "[dir]/[name].[hash]",
# see patches/0007-drop-assets-json-manifest.patch) but no assets.json manifest
# ships: get_assets_json() derives the logical name -> hashed path map from the
# dist trees at runtime, so a key can only resolve to a file nginx really has.
# This asserts exactly that: manifest gone, hashed bundles serving 200, and the
# unhashed logical URL NOT served.
# =============================================================================
docker run --rm frappe:latest bash -c '
  set -e
  /usr/local/bin/nginx-entrypoint.sh & pid=$!
  trap "kill $pid 2>/dev/null || true" EXIT

  # Resolve the hashed desk bundle from the served tree (same derivation as
  # get_assets_json): exactly one "<name>.<hash>.<ext>" match per bundle.
  resolve() {
    ls "$1"/"$2".*.js "$1"/"$2".*.css 2>/dev/null | grep -v "\.map$" | head -n 1
  }
  BUNDLE=""
  for i in $(seq 1 20); do
    BUNDLE=$(resolve sites/assets/frappe/dist/js desk.bundle || true)
    [ -n "$BUNDLE" ] && break
    sleep 1
  done
  test -n "$BUNDLE" || { echo "no hashed desk.bundle file in dist tree"; exit 1; }
  BUNDLE_URL="/${BUNDLE#./}"

  # nginx is backgrounded and needs a moment to bind; curl exits nonzero
  # (killing the script silently under set -e) if we race it.
  for i in $(seq 1 30); do
    curl -s -o /dev/null http://127.0.0.1:8080/ 2>/dev/null && break
    sleep 1
  done
  curl -s -o /dev/null http://127.0.0.1:8080/ 2>/dev/null \
    || { echo "nginx never came up on 8080"; exit 1; }

  # The manifest must be gone from disk ...
  if [ -e sites/assets/assets.json ]; then
    echo "assets.json manifest still present:" >&2
    ls -la sites/assets/assets.json >&2
    find sites/assets -maxdepth 1 -printf "%y %p -> %l\n" >&2
    find apps/frappe/frappe/public -maxdepth 1 -printf "%y %p -> %l\n" 2>/dev/null | head -20 >&2
    find apps/frappe/frappe -name assets.json >&2
    exit 1
  fi
  # ... and 404 over HTTP (nginx `try_files $uri =404`).
  MANIFEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/assets/assets.json)
  test "$MANIFEST_CODE" = 404

  # Hashed bundle + static paths must serve 200.
  for path in \
    "$BUNDLE_URL" \
    /assets/frappe/css/frappe.css \
    /assets/frappe/node_modules/ace-builds/src-min-noconflict/ace.js ; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080$path")
    test "$CODE" = 200 || { echo "Unexpected $path -> HTTP $CODE"; exit 1; }
    echo "  ok $path (HTTP $CODE)"
  done

  # The unhashed logical URL must NOT be served: the hash segment is the
  # content contract frappe links to.
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/assets/frappe/dist/js/desk.bundle.js)
  test "$CODE" != 200 || { echo "unhashed desk.bundle.js unexpectedly served HTTP 200"; exit 1; }
  echo "  ok unhashed desk.bundle.js not served (HTTP $CODE)"

  SERVER_HDR=$(curl -sI "http://127.0.0.1:8080$BUNDLE_URL" | tr -d "\r" | awk -F": " "tolower(\$1)==\"server\" {print \$2; exit}")
  case "$SERVER_HDR" in nginx*) ;; *) echo "Unexpected Server header: $SERVER_HDR"; exit 1 ;; esac

  # Hashed filenames may be cached immutably by extension; anything else must
  # at least revalidate. nginx serves /assets with Cache-Control: no-cache,
  # which is always correct for hashed URLs too.
  CC=$(curl -sI "http://127.0.0.1:8080$BUNDLE_URL" | tr -d "\r" | awk -F": " "tolower(\$1)==\"cache-control\" {print \$2; exit}")
  case "$CC" in *no-cache*) ;; *) echo "Unexpected Cache-Control: $CC"; exit 1 ;; esac

  echo "Nginx served hashed bundles, no assets.json (manifest=$MANIFEST_CODE, cache-control=$CC)"
'
