#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Build the patched production image (variant=latest) straight into the LOCAL
# Docker daemon (--load). The `frappe` (latest) build target applies the full
# patch set (APPLY_PATCHES=true) and shares the dependency/bench stages with
# the `frappe-base` (unpatched) target built by base-build.sh. Distinct gha
# cache scope so an unpatched base layer can never be mistaken for latest.
docker buildx build \
  --target frappe \
  --build-arg APPLY_PATCHES=true \
  --load \
  --cache-from type=gha,scope=frappe-latest \
  --cache-to type=gha,mode=max,scope=frappe-latest \
  -t frappe:latest \
  .