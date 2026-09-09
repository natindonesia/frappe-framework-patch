#!/usr/bin/env bash
# Assert that a single trace carries BOTH the nginx leg and the app leg.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

compose exec -T nginx curl -s -H "Host: crm.localhost" http://127.0.0.1:8080/api/method/ping
for i in $(seq 1 20); do
  trace_map=$(compose logs otel-collector | awk '
    /service\.name: Str\(/ {
      s=$0; sub(/.*service\.name: Str\(/,"",s); sub(/\).*/,"",s); svc=s
    }
    /Trace ID[[:space:]]*:/ { gsub(/.*: /,""); print $1, svc }
  ' | sort -u)
  trace=$(echo "$trace_map" | awk '
    { t=$1; s=$2; svc[t","s]=1; have[t]=1 }
    END { for (t in have) if (svc[t",frappe-nginx"] && svc[t",frappe-app"]) { print t; exit } }
  ')
  [ -n "$trace" ] && break
  sleep 2
done
if [ -n "$trace" ]; then
  echo "trace continuity OK: $trace (frappe-nginx + frappe-app)"
  exit 0
fi
echo "::error::no trace carried BOTH frappe-nginx + frappe-app after up to 40s polling"
echo "--- collected (trace, service) pairs ---"
[ -n "$trace_map" ] && echo "$trace_map" || echo "(collector log produced no (trace, service) pairs)"
[ -z "$trace_map" ] || {
  [ -n "$(echo "$trace_map" | grep ' frappe-nginx$')" ] || echo "MISSING: zero frappe-nginx (nginx) traces"
  [ -n "$(echo "$trace_map" | grep ' frappe-app$')" ]   || echo "MISSING: zero frappe-app (web) traces"
}
echo "--- otel-collector log tail ---"
compose logs --tail 60 otel-collector || true
exit 1