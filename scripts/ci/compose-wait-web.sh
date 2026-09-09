#!/usr/bin/env bash
# Poll the stack until the web tier answers /api/method/ping with HTTP 200.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

rounds="${CI_WAIT_ROUNDS:-30}"
ok=""
for i in $(seq 1 "$rounds"); do
  code=$(compose exec -T nginx curl -s -o /dev/null -w "%{http_code}" -H "Host: crm.localhost" http://127.0.0.1:8080/api/method/ping || true)
  [ "$code" = "200" ] && ok=1 && break
  sleep 2
done
[ -n "$ok" ] || { compose logs web nginx; exit 1; }
echo "web ready (HTTP 200)"