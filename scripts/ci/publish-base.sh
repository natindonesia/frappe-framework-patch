#!/usr/bin/env bash
# Promote the exact tested vanilla image to the configured registries and
# publish the immutable release tag derived from the pinned Frappe version.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_registry
FRAPPE_VERSION="$(image_frappe_version frappe:base)"
export FRAPPE_VERSION
echo "Publishing unpatched base image (Frappe ${FRAPPE_VERSION})"

if [ "${PUBLISH_MOVING_TAGS:-1}" = "1" ]; then
  publish_all frappe:base frappe:base
fi
publish_all frappe:base "frappe:${FRAPPE_VERSION}-base"
