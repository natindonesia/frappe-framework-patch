#!/usr/bin/env bash
# Trivy image scan for every built variant. Detects:
#   * vuln     -- OS + language dependency CVEs (OWASP A06 vulnerable/outdated components)
#   * secret   -- leaked credentials baked into image layers (OWASP A02/A05)
#   * misconfig-- insecure image/config posture sourced from the image
#
# Each image is written to its own SARIF report (consumed by the workflow's
# upload step) and the script exits non-zero when any image has a finding at or
# above SECURITY_SEVERITY (default CRITICAL,HIGH), which gates publish.
#
# Usage: security-scan-images.sh [image ...]
# Env: SECURITY_SEVERITY (default CRITICAL,HIGH), SECURITY_EXIT_CODE (default 1),
#      SECURITY_FAIL_ON_FINDINGS (default true), TRIVY_IGNORE_UNFIXED (default false)
set -euo pipefail
# shellcheck source=scripts/ci/security-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/security-lib.sh"

install_trivy
OUT="$(sarif_dir)"

SEVERITY="${SECURITY_SEVERITY:-CRITICAL,HIGH}"
EXIT_CODE="${SECURITY_EXIT_CODE:-1}"
FAIL="${SECURITY_FAIL_ON_FINDINGS:-true}"

images=("$@")
if [ "${#images[@]}" -eq 0 ]; then
  images=(frappe:latest frappe:base frappe-granian:latest)
fi

extra=()
[ "${TRIVY_IGNORE_UNFIXED:-false}" = "true" ] && extra+=(--ignore-unfixed)

failed=0
for image in "${images[@]}"; do
  safe="$(printf '%s' "$image" | tr '/:' '__')"
  report="${OUT}/trivy-image-${safe}.sarif"
  echo "::group::Trivy image scan ${image}"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Image $image not found locally — build it before scanning" >&2
    exit 1
  fi
  trivy image \
    --scanners vuln,secret,misconfig \
    --severity "$SEVERITY" \
    --format sarif \
    --output "$report" \
    --exit-code "$EXIT_CODE" \
    --quiet --disable-telemetry \
    "${extra[@]}" \
    "$image" || failed=1
  echo "::endgroup::"
done

if [ "$failed" -ne 0 ] && [ "$FAIL" = "true" ]; then
  echo "Trivy found ${SEVERITY} findings — see ${OUT}/trivy-image-*.sarif" >&2
  exit 1
fi
echo "OK: Trivy image scan passed (severity gate: ${SEVERITY})"
