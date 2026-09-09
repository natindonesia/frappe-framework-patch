#!/usr/bin/env bash
# Verify the two published tags resolved to DISTINCT digests (so the Granian
# tag is genuinely layered on vanilla, not an identical re-tag).
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${REGISTRY_URL:?REGISTRY_URL required}"
: "${REGISTRY_NAMESPACE:?REGISTRY_NAMESPACE required}"
REGISTRY="${REGISTRY_URL}/${REGISTRY_NAMESPACE}"
V_DIGEST="$(docker buildx imagetools inspect --format '{{index .Manifest.digest}}' "${REGISTRY}/frappe:latest")"
G_DIGEST="$(docker buildx imagetools inspect --format '{{index .Manifest.digest}}' "${REGISTRY}/frappe:latest-granian")"
echo "vanilla :latest         -> $V_DIGEST"
echo "granian :latest-granian -> $G_DIGEST"
[ -n "$V_DIGEST" ] || { echo "vanilla digest empty"; exit 1; }
[ -n "$G_DIGEST" ] || { echo "granian digest empty"; exit 1; }
[ "$V_DIGEST" != "$G_DIGEST" ] || { echo "vanilla and granian resolved to the SAME digest — check BASE_IMAGE wiring"; exit 1; }
echo "OK: vanilla and granian are distinct published images"