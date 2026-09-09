#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Build the vanilla image straight into the LOCAL Docker daemon (--load). The
# Granian build right after this relies on `frappe:latest` sitting in this same
# daemon, so the two variants really do share the tested base layers.
docker buildx build \
  --load \
  --cache-from type=gha,scope=frappe-vanilla \
  --cache-to type=gha,mode=max,scope=frappe-vanilla \
  -t frappe:latest \
  .