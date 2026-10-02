#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Build the patched production image (variant=latest) straight into the LOCAL
# Docker daemon (--load). The `frappe` (latest) target layers the patched
# builder (patches applied into the bench + frappe assets rebuilt) on top of
# the shared pristine builder-base stages that base-build.sh also consumes.
#
# Layer cache lives in a SHARED registry ref (see build_cache_ref): registry
# cache blobs are not subject to the 10 GB Actions-cache LRU eviction, and one
# shared ref means the identical base/builder stages are stored once for both
# variants (builder-patched keys separately inside the same scope, so variants
# can never collide). gha cache is kept as a restore-only fallback.
set_image_metadata_args
CACHE_REF="$(build_cache_ref)"
docker buildx build \
  --target frappe \
  "${IMAGE_METADATA_ARGS[@]}" \
  --load \
  --cache-from "type=registry,ref=${CACHE_REF}" \
  --cache-from type=gha,scope=frappe \
  --cache-to "type=registry,ref=${CACHE_REF},mode=max" \
  -t frappe:latest \
  .