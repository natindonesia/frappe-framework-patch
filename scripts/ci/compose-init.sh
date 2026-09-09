#!/usr/bin/env bash
# Run the init container explicitly with live logs (idempotent init path).
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

compose run --rm init