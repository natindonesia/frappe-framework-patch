#!/usr/bin/env bash
# Bring up the remaining application stack (worker(s), web, socketio, nginx).
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

compose up -d web socketio worker schedule worker-long worker-short nginx