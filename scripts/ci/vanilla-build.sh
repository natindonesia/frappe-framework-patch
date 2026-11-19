#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Build the patched production image (variant=latest) straight into the LOCAL
# Docker daemon (--load). The `frappe` (latest) target layers the patched
# builder (patches applied into the bench + frappe assets rebuilt) on top of
# the shared pristine builder-base stages that base-build.sh also consumes.
#
# NO registry/gha cache flags (see base-build.sh): the cache is the runner's
# buildx builder backed by Blacksmith's sticky disk, keyed per architecture in
# the workflow. The builder-base stages shared with base-build.sh are cached
# there, so patch edits still never re-run `bench init`.
set_image_metadata_args
docker buildx build \
  --target frappe \
  "${IMAGE_METADATA_ARGS[@]}" \
  --load \
  -t frappe:latest \
  .
