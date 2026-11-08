#!/usr/bin/env bash
# Promote the EXACT tested local vanilla image to the configured registries:
# always as the immutable release tag derived from the pinned Frappe version,
# and as :latest when this run is allowed to move the floating tags.
# `docker tag` + `docker push` — NO second build, NO registry re-assembly.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_registry
FRAPPE_VERSION="$(image_frappe_version frappe:latest)"
export FRAPPE_VERSION
echo "Publishing patched image (Frappe ${FRAPPE_VERSION})"

if [ "${PUBLISH_MOVING_TAGS:-1}" = "1" ]; then
  publish_all frappe:latest frappe:latest
fi
publish_all frappe:latest "frappe:${FRAPPE_VERSION}"
