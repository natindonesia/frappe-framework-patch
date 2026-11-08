#!/usr/bin/env bash
# Promote the exact tested Granian image to the configured registries and
# publish the immutable release tag derived from the pinned Frappe version.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_registry
FRAPPE_VERSION="$(image_frappe_version frappe-granian:latest)"
export FRAPPE_VERSION
echo "Publishing granian image (Frappe ${FRAPPE_VERSION})"

if [ "${PUBLISH_MOVING_TAGS:-1}" = "1" ]; then
  publish_all frappe-granian:latest frappe:latest-granian
fi
publish_all frappe-granian:latest "frappe:${FRAPPE_VERSION}-granian"
