#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Build the UNPATCHED base image straight into the LOCAL Docker daemon (--load).
# It is a real, distinct artifact: the same shared dependency/bench stages as
# frappe:latest, but APPLY_PATCHES=false so ./patches are never applied and the
# `base` target label is baked in. NOT the patched production image.
docker buildx build \
  --target frappe-base \
  --build-arg APPLY_PATCHES=false \
  --load \
  --cache-from type=gha,scope=frappe-base \
  --cache-to type=gha,mode=max,scope=frappe-base \
  -t frappe:base \
  .