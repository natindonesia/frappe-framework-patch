#!/usr/bin/env bash
# Assert OTEL is gated OFF when the exporter endpoints are empty (vanilla stack).
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# The collector's batch processor (5s timeout) buffers spans and flushes them
# late, so comparing raw 'Span #' line counts before/after the restart is
# unreliable: spans generated during the OTEL-ON phase (CRUD checks) may still
# be buffered when `before` is sampled and only flushed afterwards, producing a
# false "leak". Instead, assert on span START TIMES: record the newest span
# Start time observed before gate-off, restart with empty OTLP endpoints, then
# require that NO span with a Start time after that reference appears. Buffered
# pre-existing spans carry their original (pre-gate-off) Start times, so they
# are correctly excluded.
# The collector's batch processor buffers spans and only logs them after its
# 5s timeout. After the OTEL-ON CRUD phase the final spans may still be
# buffered, so sampling the reference immediately would miss them and a
# late-flushed pre-restart span (Start time just after that too-early ref)
# would be falsely flagged as a leak. Wait until the max logged Start time
# stops increasing (collector has flushed the whole OTEL-ON batch) before
# recording the reference.
max_start() {
  compose logs otel-collector | awk '
    /Start time/ { t=$0; sub(/^.*Start time[[:space:]]*:[[:space:]]*/,"",t); if (t > m) m=t }
    END { print m }'
}
prev=""
for _ in $(seq 1 15); do
  cur=$(max_start)
  [ -n "$prev" ] && [ "$cur" = "$prev" ] && break
  prev="$cur"
  sleep 1
done
# The collector's batch timeout is 5s. The stabilization loop above can exit as
# soon as max_start looks stable, but a final 5s batch flush may still land right
# after it breaks. Always wait at least 6s so the whole OTEL-ON batch is
# guaranteed flushed to the collector log, THEN re-sample the reference fresh so
# any spans flushed during that wait (Start time just after the loop's snapshot)
# are still captured in the reference instead of falsely flagged as leaks.
sleep 6
before_ref="$(max_start)"

compose up -d
sleep 10
compose exec -T nginx curl -s -o /dev/null -H "Host: crm.localhost" http://127.0.0.1:8080/api/method/ping
compose exec -T nginx curl -s -o /dev/null -H "Host: crm.localhost" http://127.0.0.1:8080/api/method/ping
compose logs nginx | grep -q 'OpenTelemetry disabled' || { echo "gate-off log missing"; exit 1; }

# After gate-off, no span may carry a Start time newer than the reference.
leaked=$(compose logs otel-collector | awk -v ref="$before_ref" '
  /Start time/ { t=$0; sub(/^.*Start time[[:space:]]*:[[:space:]]*/,"",t); if (t > ref) n++ }
  END { print n+0 }')
[ "$leaked" -eq 0 ] || { echo "spans leaked with gate off: $leaked span(s) after $before_ref"; exit 1; }
echo "gate-off OK (no spans after $before_ref)"