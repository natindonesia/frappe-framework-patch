#!/usr/bin/env bash
# Build the Granian variant layered on the local vanilla image (SAME daemon).
#
# Plain `docker build` (default builder = local daemon) so `FROM ${BASE_IMAGE}`
# in Dockerfile.granian resolves to the `frappe:latest` image --load'ed just
# above IN TO THIS SAME daemon. `docker buildx` would use an isolated container
# builder that instead tries to pull the base from docker.io. This keeps the
# Granian image a thin layer genuinely derived from the tested vanilla result.
#
# --provenance=false --sbom=false is NOT cosmetic. A plain `docker build` keeps
# BuildKit's default provenance attestation, so the image in the daemon is an
# OCI INDEX (the image plus an "unknown/unknown" attestation manifest). `docker
# push` then publishes that index, and the multi-arch merge fails its digest
# assertion because the tag's digest is the index, not the amd64 child:
#   "latest-granian amd64 child (sha256:38cc…) is not latest-granian-amd64
#    (sha256:25dd…)"
# The `--load` builds above are immune (type=docker output drops attestations).
# Provenance and the SBOM are attached later, deliberately, by the attest job.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set_image_metadata_args
docker build \
  --provenance=false --sbom=false \
  --build-arg BASE_IMAGE=frappe:latest \
  "${IMAGE_METADATA_ARGS[@]}" \
  -t frappe-granian:latest \
  -f Dockerfile.granian \
  .