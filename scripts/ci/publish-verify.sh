#!/usr/bin/env bash
# Verify the three published tags exist in EVERY configured registry and resolve
# to DISTINCT digests, so each variant is genuinely its own artifact:
#   - frappe:base           (unpatched reference image)
#   - frappe:latest         (patched production image)
#   - frappe:latest-granian (Granian layered on patched latest)
# When two registries are configured, each tag must resolve to the SAME digest
# in both — proof the same tested image was actually published twice.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_registry
PRIMARY="$(primary_registry)"
SECONDARY="$(secondary_registry)"

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

P_BASE=""; P_LATEST=""; P_GRANIAN=""
if [ -n "$PRIMARY" ]; then
  verify_registry "$PRIMARY" primary
  P_BASE="$VERIFIED_BASE"; P_LATEST="$VERIFIED_LATEST"; P_GRANIAN="$VERIFIED_GRANIAN"
else
  echo "Primary registry not configured — verifying the secondary only"
fi

if [ -n "$SECONDARY" ]; then
  verify_registry "$SECONDARY" secondary
  if [ -n "$PRIMARY" ]; then
    [ "$VERIFIED_BASE" = "$P_BASE" ] || { echo "  secondary :base digest differs from primary — not the same tested image"; exit 1; }
    [ "$VERIFIED_LATEST" = "$P_LATEST" ] || { echo "  secondary :latest digest differs from primary — not the same tested image"; exit 1; }
    [ "$VERIFIED_GRANIAN" = "$P_GRANIAN" ] || { echo "  secondary :latest-granian digest differs from primary — not the same tested image"; exit 1; }
    echo "OK: ${PRIMARY} and ${SECONDARY} hold the same three distinct images"
  else
    echo "OK: ${SECONDARY} holds three distinct images"
  fi
else
  echo "Secondary registry not configured — verified ${PRIMARY} only"
fi
echo "OK: base, latest, and latest-granian are three distinct published images"
