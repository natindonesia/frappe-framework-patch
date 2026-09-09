#!/usr/bin/env bash
# Diagnostic dump, run on step failure to help triage compose/OTEL breakage.
set -uo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

compose ps -a || true
echo "--- otel-collector logs ---"
compose logs otel-collector || true
echo "--- web/nginx logs ---"
compose logs web nginx || true