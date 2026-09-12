#!/usr/bin/env bash
# Verify the three published tags exist in the registry and resolve to DISTINCT
# digests, so each variant is genuinely its own artifact:
#   - frappe:base           (unpatched reference image)
#   - frappe:latest         (patched production image)
#   - frappe:latest-granian (Granian layered on patched latest)
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${REGISTRY_URL:?REGISTRY_URL required}"
: "${REGISTRY_NAMESPACE:?REGISTRY_NAMESPACE required}"
REGISTRY="${REGISTRY_URL}/${REGISTRY_NAMESPACE}"
B_DIGEST="$(docker buildx imagetools inspect "${REGISTRY}/frappe:base" | awk '/^Digest:/ {print $2; exit}')"
V_DIGEST="$(docker buildx imagetools inspect "${REGISTRY}/frappe:latest" | awk '/^Digest:/ {print $2; exit}')"
G_DIGEST="$(docker buildx imagetools inspect "${REGISTRY}/frappe:latest-granian" | awk '/^Digest:/ {print $2; exit}')"
echo "base           :base             -> $B_DIGEST"
echo "patched        :latest           -> $V_DIGEST"
echo "granian        :latest-granian   -> $G_DIGEST"
[ -n "$B_DIGEST" ] || { echo "  base digest empty"; exit 1; }
[ -n "$V_DIGEST" ] || { echo "  latest digest empty"; exit 1; }
[ -n "$G_DIGEST" ] || { echo "  granian digest empty"; exit 1; }
[ "$B_DIGEST" != "$V_DIGEST" ] || { echo "  base and latest resolved to the SAME digest — check APPLY_PATCHES wiring"; exit 1; }
[ "$V_DIGEST" != "$G_DIGEST" ] || { echo "  latest and granian resolved to the SAME digest — check BASE_IMAGE wiring"; exit 1; }
[ "$B_DIGEST" != "$G_DIGEST" ] || { echo "  base and granian resolved to the SAME digest — unexpected"; exit 1; }
echo "OK: base, latest, and latest-granian are three distinct published images"