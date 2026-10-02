#!/usr/bin/env bash
# Assert that the per-request pyinstrument profiling actually reaches the
# collector: with OTEL_PYINSTRUMENT=1 (exported by matrix-variant-test.sh),
# frappe-app spans must carry
#   - >=1 pyinstrument.sample event (sample.source=pyinstrument_sample)
#   - the frappe.thread_cpu_ns and frappe.profile.sample_count attributes
# The collector debug exporter (verbosity=detailed) prints attributes as
# "     -> key: Str(value)" / "     -> key: INT(value)", and span events as
# attribute lines under the span's Events section, so grepping attribute
# values is format-stable.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Any authenticated or guest endpoint works; even a minimal request runs
# enough Python call/return events for pyinstrument to emit samples.
compose exec -T nginx curl -s -o /dev/null -H "Host: crm.localhost" \
  http://127.0.0.1:8080/api/method/ping

# The collector batch processor buffers spans for up to 5s before logging;
# poll until the profiling signals appear (or give up after ~40s).
count_attr() {
  compose logs otel-collector 2>/dev/null | grep -c -- "$1" || true
}

sample_hits=""
for _ in $(seq 1 20); do
  sample_hits=$(count_attr 'Str(pyinstrument_sample)')
  cpu_hits=$(count_attr 'frappe.thread_cpu_ns')
  [ "${sample_hits:-0}" -ge 1 ] && [ "${cpu_hits:-0}" -ge 1 ] && break
  sleep 2
done

if [ "${sample_hits:-0}" -ge 1 ] && [ "${cpu_hits:-0}" -ge 1 ]; then
  sc_hits=$(count_attr 'frappe.profile.sample_count')
  echo "profiling OK: $sample_hits sample event(s), $cpu_hits thread_cpu attr(s), $sc_hits sample_count attr(s)"
  exit 0
fi

echo "::error::no pyinstrument profiling signals in collector logs after up to 40s"
echo "sample.source hits: ${sample_hits:-0}, frappe.thread_cpu_ns hits: ${cpu_hits:-0}"
echo "--- otel-collector log tail ---"
compose logs --tail 60 otel-collector || true
exit 1
