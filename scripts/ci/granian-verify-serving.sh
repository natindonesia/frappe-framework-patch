#!/usr/bin/env bash
# Assert the compose `web` service is actually served by Granian (not gunicorn).
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

web_id=$(compose ps -q web)
cmd=$(docker exec "$web_id" sh -c 'tr "\000" " " < /proc/1/cmdline')
echo "web PID1 cmdline: $cmd"
if echo "$cmd" | grep -qE 'granian.*otel_wsgi' && ! echo "$cmd" | grep -q 'gunicorn'; then
  echo "web service is serving via granian"
else
  echo "::error::web service is not running granian (see PID1 cmdline above)"
  exit 1
fi