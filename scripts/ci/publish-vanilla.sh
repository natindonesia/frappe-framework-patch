#!/usr/bin/env bash
# Promote the EXACT tested local vanilla image to the registry as :latest.
# `docker tag` + `docker push` — NO second build, NO registry re-assembly.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${REGISTRY_URL:?REGISTRY_URL required}"
: "${REGISTRY_NAMESPACE:?REGISTRY_NAMESPACE required}"
REGISTRY="${REGISTRY_URL}/${REGISTRY_NAMESPACE}"
echo "Publishing tested vanilla -> ${REGISTRY}/frappe:latest"
docker tag frappe:latest "${REGISTRY}/frappe:latest"
docker push "${REGISTRY}/frappe:latest"