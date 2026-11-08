#!/usr/bin/env bash
# Promote the EXACT tested local Granian image (layered on this run's vanilla)
# to the configured registries as :latest-granian. NO re-build, NO re-assembly on
# another runner.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_registry
echo "Publishing tested granian image"
publish_all frappe-granian:latest frappe:latest-granian
