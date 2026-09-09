#!/usr/bin/env bash
# Tear the stack down WITHOUT -v: the project volumes persist so later runs
# exercise the idempotent init path. A poisoned volume is fixed manually with
# `docker volume rm <project>_*` — never automated, never `down -v`.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

compose down --remove-orphans