#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Build the UNPATCHED base image straight into the LOCAL Docker daemon (--load).
# It is a real, distinct artifact: the same shared dependency/bench stages as
# frappe:latest, but APPLY_PATCHES=false so ./patches are never applied and the
# `base` target label is baked in. NOT the patched production image.
#
# SAME registry cache ref as vanilla-build.sh (shared base/builder stages);
# the ARG-gated patch RUN keys differently inside the shared scope, so the
# variants stay distinct without duplicating the dependency cache blobs.
set_image_metadata_args
CACHE_REF="$(build_cache_ref)"
docker buildx build \
  --target frappe-base \
  --build-arg APPLY_PATCHES=false \
  "${IMAGE_METADATA_ARGS[@]}" \
  --load \
  --cache-from "type=registry,ref=${CACHE_REF}" \
  --cache-from type=gha,scope=frappe \
  --cache-to "type=registry,ref=${CACHE_REF},mode=max" \
  -t frappe:base \
  .