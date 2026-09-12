#!/usr/bin/env bash
# Promote the EXACT tested local UNPATCHED base image -> registry as :base.
# `docker tag` + `docker push` — NO second build, NO registry re-assembly.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${REGISTRY_URL:?REGISTRY_URL required}"
: "${REGISTRY_NAMESPACE:?REGISTRY_NAMESPACE required}"
REGISTRY="${REGISTRY_URL}/${REGISTRY_NAMESPACE}"
echo "Publishing tested base -> ${REGISTRY}/frappe:base"
docker tag frappe:base "${REGISTRY}/frappe:base"
docker push "${REGISTRY}/frappe:base"