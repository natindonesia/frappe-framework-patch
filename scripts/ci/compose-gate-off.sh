#!/usr/bin/env bash
# Assert OTEL is gated OFF when the exporter endpoints are empty (vanilla stack).
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

before=$(compose logs --since 1m otel-collector | grep -c 'Span #' || true)
compose up -d
sleep 10
compose exec -T nginx curl -s -o /dev/null -H "Host: crm.localhost" http://127.0.0.1:8080/api/method/ping
compose exec -T nginx curl -s -o /dev/null -H "Host: crm.localhost" http://127.0.0.1:8080/api/method/ping
after=$(compose logs --since 1m otel-collector | grep -c 'Span #' || true)
compose logs nginx | grep -q 'OpenTelemetry disabled' || { echo "gate-off log missing"; exit 1; }
[ "$after" -le "$before" ] || { echo "spans leaked with gate off: $before -> $after"; exit 1; }
echo "gate-off OK (spans: $before -> $after)"