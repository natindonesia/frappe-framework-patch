#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Build the patched production image (variant=latest) straight into the LOCAL
# Docker daemon (--load). The `frappe` (latest) build target applies the full
# patch set (APPLY_PATCHES=true) and shares the dependency/bench stages with
# the `frappe-base` (unpatched) target built by base-build.sh.
#
# Layer cache lives in a SHARED registry ref (see build_cache_ref): registry
# cache blobs are not subject to the 10 GB Actions-cache LRU eviction, and one
# shared ref means the identical base/builder stages are stored once for both
# variants (the ARG-gated patch RUN gets distinct keys inside the same scope,
# so variants can never collide). gha cache is kept as a restore-only fallback.
set_image_metadata_args
CACHE_REF="$(build_cache_ref)"
docker buildx build \
  --target frappe \
  --build-arg APPLY_PATCHES=true \
  "${IMAGE_METADATA_ARGS[@]}" \
  --load \
  --cache-from "type=registry,ref=${CACHE_REF}" \
  --cache-from type=gha,scope=frappe \
  --cache-to "type=registry,ref=${CACHE_REF},mode=max" \
  -t frappe:latest \
  .