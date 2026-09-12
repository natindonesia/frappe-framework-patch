#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

docker run --rm frappe:latest bash -c '
  ./env/bin/gunicorn --version
  ./env/bin/python -c "import frappe; print(\"Frappe version: %s\" % frappe.__version__)"
  ./env/bin/python -c "from frappe.otel_wsgi import application; print(\"WSGI application import OK\")"
  ./env/bin/gunicorn --chdir=/home/frappe/frappe-bench/sites --bind=127.0.0.1:8001 --workers=1 --worker-class=sync --timeout=30 --config=/home/frappe/frappe-bench/apps/frappe/resources/gunicorn-otel-conf.py frappe.otel_wsgi:application >/tmp/gunicorn.log 2>&1 & GUNICORN_PID=$!
  trap "kill $GUNICORN_PID 2>/dev/null || true" EXIT
  ok=0
  for i in $(seq 1 40); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8001/api/method/ping || true)
    if [ -n "$CODE" ] && [ "$CODE" != 000 ]; then ok=1; break; fi
    sleep 1
  done
  if [ "$ok" != 1 ] || [ "$CODE" != 200 ]; then
    cat /tmp/gunicorn.log
    echo "Gunicorn answered /api/method/ping with HTTP $CODE; expected HTTP 200"
    exit 1
  fi
  echo "Gunicorn answered /api/method/ping with HTTP $CODE"
'