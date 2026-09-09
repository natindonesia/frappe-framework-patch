#!/usr/bin/env bash
# Promote the EXACT tested local Granian image (layered on this run's vanilla)
# -> registry tag latest-granian. NO re-build, NO re-assembly on another runner.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${REGISTRY_URL:?REGISTRY_URL required}"
: "${REGISTRY_NAMESPACE:?REGISTRY_NAMESPACE required}"
REGISTRY="${REGISTRY_URL}/${REGISTRY_NAMESPACE}"
echo "Publishing tested granian -> ${REGISTRY}/frappe:latest-granian"
docker tag frappe-granian:latest "${REGISTRY}/frappe:latest-granian"
docker push "${REGISTRY}/frappe:latest-granian"