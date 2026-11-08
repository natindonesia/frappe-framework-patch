#!/usr/bin/env bash
# Promote the EXACT tested local vanilla image to the configured registries as
# :latest. `docker tag` + `docker push` — NO second build, NO registry
# re-assembly. Every configured registry is attempted independently, so an
# unavailable primary does not block the secondary.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_registry
echo "Publishing tested vanilla image"
publish_all frappe:latest frappe:latest
