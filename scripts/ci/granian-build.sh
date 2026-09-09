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

docker build \
  --build-arg BASE_IMAGE=frappe:latest \
  -t frappe-granian:latest \
  -f Dockerfile.granian \
  .