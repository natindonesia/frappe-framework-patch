#!/usr/bin/env bash
# Semgrep SAST mapped to the two requested rule packs:
#   * p/owasp-top-ten -- OWASP Top 10 (2021) web application risks
#   * p/cwe-top-25    -- CWE Top 25 most dangerous software weaknesses
#     ("OWASP 25" is read as the CWE Top 25, the industry-standard companion list)
#
# Findings at or above SEMGREP_SEVERITY (default ERROR) fail the job so publish
# is gated. Additional packs can be appended via SEMGREP_EXTRA_CONFIGS.
#
# Env: SEMGREP_TARGETS (default "scripts resources runtime tests patches"),
#      SEMGREP_EXCLUDE (default "frappe"), SEMGREP_SEVERITY (default ERROR)
set -euo pipefail
# shellcheck source=scripts/ci/security-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/security-lib.sh"

install_semgrep
OUT="$(sarif_dir)"

TARGETS="${SEMGREP_TARGETS:-scripts resources runtime tests patches}"
EXCLUDE="${SEMGREP_EXCLUDE:-frappe}"
SEVERITY="${SEMGREP_SEVERITY:-ERROR}"

configs=(--config p/owasp-top-ten --config p/cwe-top-25)
for c in ${SEMGREP_EXTRA_CONFIGS:-}; do configs+=(--config "$c"); done

excludes=()
for d in $EXCLUDE; do excludes+=(--exclude "$d"); done

echo "::group::Semgrep SAST (OWASP Top 10 + CWE Top 25)"
set +e
semgrep scan \
  "${configs[@]}" \
  --severity "$SEVERITY" \
  --sarif \
  --output "${OUT}/semgrep.sarif" \
  --error \
  --metrics=off \
  --disable-version-check \
  "${excludes[@]}" \
  $TARGETS
rc=$?
set -e
echo "::endgroup::"

if [ "$rc" -ne 0 ]; then
  echo "Semgrep reported ${SEVERITY} findings — see ${OUT}/semgrep.sarif" >&2
  exit "$rc"
fi
echo "OK: Semgrep SAST passed (severity gate: ${SEVERITY})"
