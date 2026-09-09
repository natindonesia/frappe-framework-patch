#!/usr/bin/env bash
# Clean up leftover containers from a previous run for a compose project.
# Usage: compose-cleanup.sh [-v]   (-v also wipes volumes; used only for the
# vanilla stack where init must run from a clean slate on a fresh cache).
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ "${1:-}" = "-v" ]; then
  compose down -v --remove-orphans 2>/dev/null || true
else
  compose down --remove-orphans 2>/dev/null || true
fi