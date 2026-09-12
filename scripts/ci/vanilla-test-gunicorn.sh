#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Pre-validation (no site initialized): prove gunicorn boots, imports the WSGI
# app, and actually serves HTTP. The standalone image has NO initialized site /
# Host context, so site-routed endpoints (e.g. /api/method/ping) intentionally
# return a non-200 (404) - a 404 is still a valid HTTP response proving the
# listener is up and routing into the Frappe WSGI app. The REQUIRED "pong"/200
# is asserted later by matrix-variant-test.sh against the fully-initialized
# compose stack; do NOT require 200 here.
docker run --rm frappe:latest bash -c '
  cd sites
  ../env/bin/gunicorn --bind=127.0.0.1:8001 --workers=1 --worker-class=sync --timeout=30 --config=/home/frappe/frappe-bench/apps/frappe/resources/gunicorn-otel-conf.py frappe.otel_wsgi:application >/tmp/gunicorn.log 2>&1 & GUNICORN_PID=$!
  trap "kill $GUNICORN_PID 2>/dev/null || true" EXIT
  ok=0
  for i in $(seq 1 40); do
    # Worker boot == gunicorn accepted the bind and initialized the WSGI app.
    if grep -q "Booting worker" /tmp/gunicorn.log 2>/dev/null; then
      # Any HTTP status (incl. 404 for site-routed paths) proves real serving.
      CODE=$(curl -s -o /tmp/body -w "%{http_code}" --max-time 3 http://127.0.0.1:8001/api/method/ping || true)
      if [ -n "$CODE" ] && [ "$CODE" != 000 ]; then ok=1; BREAK_CODE=$CODE; break; fi
    fi
    kill -0 "$GUNICORN_PID" 2>/dev/null || break
    sleep 1
  done
  if [ "$ok" != 1 ]; then
    echo "::error::Gunicorn did not report a worker boot + HTTP response"
    cat /tmp/gunicorn.log
    exit 1
  fi
  BODY=$(tr -d "\n\r" < /tmp/body | head -c 200)
  echo "OK: Gunicorn worker booted and served HTTP; /api/method/ping -> HTTP $BREAK_CODE (site-routed status expected without an initialized site; required pong/200 asserted later by compose matrix)"
  echo "response body: $BODY"
  echo "--- gunicorn log ---"
  cat /tmp/gunicorn.log
'