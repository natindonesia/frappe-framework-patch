#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Build the UNPATCHED base image straight into the LOCAL Docker daemon (--load).
# It is a real, distinct artifact: it deploys from the shared pristine
# builder-base stages (no patches applied, `base` label baked in), which the
# patched frappe:latest then layers on top of. NOT the patched production image.
#
# NO registry/gha cache flags: the layer cache is the runner's own buildx
# builder (docker/setup-buildx-action in the workflow). Nothing is written to a
# registry, so there is no frappe-buildcache package and no cache credentials
# needed. The cache lives only as long as the job, so each leg starts cold.
set_image_metadata_args
docker buildx build \
  --provenance=false --sbom=false \
  --target frappe-base \
  "${IMAGE_METADATA_ARGS[@]}" \
  --load \
  -t frappe:base \
  .
