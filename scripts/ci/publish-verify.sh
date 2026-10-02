#!/usr/bin/env bash
# Verify the three published tags exist in EVERY configured registry and resolve
# to DISTINCT digests, so each variant is genuinely its own artifact:
#   - frappe:base           (unpatched reference image)
#   - frappe:latest         (patched production image)
#   - frappe:latest-granian (Granian layered on patched latest)
# When a secondary registry (ghcr.io) is configured, each tag must resolve to the
# SAME digest there as in the primary registry — proof it was actually published.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${REGISTRY_URL:?REGISTRY_URL required}"
: "${REGISTRY_NAMESPACE:?REGISTRY_NAMESPACE required}"
REGISTRY="${REGISTRY_URL}/${REGISTRY_NAMESPACE}"

imagetools_digest() {
  docker buildx imagetools inspect "$1" | awk '/^Digest:/ {print $2; exit}'
}

verify_registry() {
  local registry="$1" label="$2" b v g
  b="$(imagetools_digest "${registry}/frappe:base")"
  v="$(imagetools_digest "${registry}/frappe:latest")"
  g="$(imagetools_digest "${registry}/frappe:latest-granian")"
  echo "[${label}] base           :base             -> $b"
  echo "[${label}] patched        :latest           -> $v"
  echo "[${label}] granian        :latest-granian   -> $g"
  [ -n "$b" ] || { echo "  ${label} base digest empty"; exit 1; }
  [ -n "$v" ] || { echo "  ${label} latest digest empty"; exit 1; }
  [ -n "$g" ] || { echo "  ${label} granian digest empty"; exit 1; }
  [ "$b" != "$v" ] || { echo "  ${label} base and latest resolved to the SAME digest — check Dockerfile patch wiring"; exit 1; }
  [ "$v" != "$g" ] || { echo "  ${label} latest and granian resolved to the SAME digest — check BASE_IMAGE wiring"; exit 1; }
  [ "$b" != "$g" ] || { echo "  ${label} base and granian resolved to the SAME digest — unexpected"; exit 1; }
  VERIFIED_BASE="$b"; VERIFIED_LATEST="$v"; VERIFIED_GRANIAN="$g"
}

verify_registry "$REGISTRY" primary
P_BASE="$VERIFIED_BASE"; P_LATEST="$VERIFIED_LATEST"; P_GRANIAN="$VERIFIED_GRANIAN"

SECONDARY="$(secondary_registry)"
if [ -n "$SECONDARY" ]; then
  verify_registry "$SECONDARY" secondary
  [ "$VERIFIED_BASE" = "$P_BASE" ] || { echo "  secondary :base digest differs from primary — not the same tested image"; exit 1; }
  [ "$VERIFIED_LATEST" = "$P_LATEST" ] || { echo "  secondary :latest digest differs from primary — not the same tested image"; exit 1; }
  [ "$VERIFIED_GRANIAN" = "$P_GRANIAN" ] || { echo "  secondary :latest-granian digest differs from primary — not the same tested image"; exit 1; }
  echo "OK: ${REGISTRY} and ${SECONDARY} hold the same three distinct images"
else
  echo "Secondary registry not configured — verified ${REGISTRY} only"
fi
echo "OK: base, latest, and latest-granian are three distinct published images"
