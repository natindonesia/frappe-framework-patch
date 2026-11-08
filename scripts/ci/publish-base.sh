#!/usr/bin/env bash
# Promote the EXACT tested local UNPATCHED base image to the configured
# registries as :base. `docker tag` + `docker push` — NO second build, NO
# registry re-assembly.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_registry
echo "Publishing tested base image"
publish_all frappe:base frappe:base
