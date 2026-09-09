#!/usr/bin/env bash
# Assert /api/method/ping through Granian + nginx returns a pong.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

body=$(compose exec -T nginx curl -s -H "Host: crm.localhost" http://127.0.0.1:8080/api/method/ping)
echo "ping response: $body"
echo "$body" | grep -q '"message":"pong"' || { echo "::error::expected pong, got: $body"; exit 1; }