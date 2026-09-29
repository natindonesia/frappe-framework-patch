#!/usr/bin/env bash
# Trivy filesystem + config (IaC) scan of the checked-out source tree. Detects:
#   * vuln      -- dependency CVEs from lockfiles/requirements (OWASP A06)
#   * secret    -- credentials committed to the repo (OWASP A02/A05)
#   * misconfig -- Dockerfile / compose / CI YAML hardening issues (OWASP A05)
#
# Writes two SARIF reports (fs + config) and exits non-zero when a finding at or
# above SECURITY_SEVERITY is present, gating publish.
#
# Env: SECURITY_SOURCE_TARGETS (default .), TRIVY_SKIP_DIRS (default frappe),
#      SECURITY_SEVERITY (default CRITICAL,HIGH), SECURITY_EXIT_CODE (default 1),
#      SECURITY_FAIL_ON_FINDINGS (default true), TRIVY_IGNORE_UNFIXED (default false)
set -euo pipefail
# shellcheck source=scripts/ci/security-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/security-lib.sh"

install_trivy
OUT="$(sarif_dir)"

SEVERITY="${SECURITY_SEVERITY:-CRITICAL,HIGH}"
EXIT_CODE="${SECURITY_EXIT_CODE:-1}"
FAIL="${SECURITY_FAIL_ON_FINDINGS:-true}"
TARGETS="${SECURITY_SOURCE_TARGETS:-.}"
SKIP="${TRIVY_SKIP_DIRS:-frappe}"

extra=()
[ "${TRIVY_IGNORE_UNFIXED:-false}" = "true" ] && extra+=(--ignore-unfixed)
for d in $SKIP; do extra+=(--skip-dirs "$d"); done

failed=0

echo "::group::Trivy filesystem scan (${TARGETS})"
trivy fs \
  --scanners vuln,secret \
  --severity "$SEVERITY" \
  --format sarif \
  --output "${OUT}/trivy-fs.sarif" \
  --exit-code "$EXIT_CODE" \
  --quiet --disable-telemetry \
  "${extra[@]}" \
  $TARGETS || failed=1
echo "::endgroup::"

echo "::group::Trivy config (IaC) scan (${TARGETS})"
trivy config \
  --severity "$SEVERITY" \
  --format sarif \
  --output "${OUT}/trivy-config.sarif" \
  --exit-code "$EXIT_CODE" \
  --quiet --disable-telemetry \
  "${extra[@]}" \
  $TARGETS || failed=1
echo "::endgroup::"

if [ "$failed" -ne 0 ] && [ "$FAIL" = "true" ]; then
  echo "Trivy found ${SEVERITY} findings — see ${OUT}/trivy-fs.sarif and ${OUT}/trivy-config.sarif" >&2
  exit 1
fi
echo "OK: Trivy source/config scan passed (severity gate: ${SEVERITY})"
