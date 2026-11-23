#!/usr/bin/env bash
# Build the Granian variant layered on the local vanilla image (SAME daemon).
#
# Plain `docker build` (default builder = local daemon) so `FROM ${BASE_IMAGE}`
# in Dockerfile.granian resolves to the `frappe:latest` image --load'ed just
# above IN TO THIS SAME daemon. `docker buildx` would use an isolated container
# builder that instead tries to pull the base from docker.io. This keeps the
# Granian image a thin layer genuinely derived from the tested vanilla result.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set_image_metadata_args
# No buildx attestations: with BuildKit's default provenance the local image is
# stored as an OCI index (image + unknown/unknown attestation manifest), so
# `docker push` publishes a two-manifest index under the per-arch tag and the
# multi-arch merge then finds a child that is not that tag's digest. base and
# latest are built with `buildx --load`, which drops attestations, so all three
# variants have to stay single-manifest for the merge assertion to hold.
docker build \
  --provenance=false \
  --sbom=false \
  --build-arg BASE_IMAGE=frappe:latest \
  "${IMAGE_METADATA_ARGS[@]}" \
  -t frappe-granian:latest \
  -f Dockerfile.granian \
  .