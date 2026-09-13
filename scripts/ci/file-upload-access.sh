#!/usr/bin/env bash
# File upload + file access sanity through nginx.
#
# DevOps-level HTTP contract only — deliberately asserts the request/response
# boundary, never Frappe's internal upload/permission implementation:
#   * POST /api/method/upload_file   -> 403 for Guest, 200 for Administrator
#   * GET  /api/method/download_file -> 403 for Guest on a PRIVATE file, 200 logged in
#   * GET  /files/<name>             -> 200 for a PUBLIC file, even for Guest
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Reconstruct the exact docker-compose exec command for the nginx curl client.
cmd_parts=(docker compose -p "${CI_PROJECT}" -f docker-compose.yml -f resources/compose.ci.yml)
for f in ${EXTRA_FILES:-}; do
  [ -n "$f" ] && cmd_parts+=(-f "$f")
done
cmd_parts+=(exec -T nginx curl -sS --max-time 60)
CMD="${cmd_parts[*]}"

HDR="Host: crm.localhost"
CK=/tmp/upload_cookie.$$
LF=/tmp/upload_log.$$
trap 'rm -f "$CK" "$LF"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS: $*"; }
bad() { fail=$((fail+1)); echo "  FAIL: $*"; }
status() {
  echo "------"
  echo "\$ $*"
  "$@" -w $'\nHTTP_STATUS:%{http_code}' 2>&1 | tee "$LF" || true
  HTTP_STATUS="$(grep -oE 'HTTP_STATUS:[0-9]+$' "$LF" | tail -1 | cut -d: -f2)"
  HTTP_BODY="$(sed '$d' "$LF")"
}
json_field() {
  printf '%s' "$HTTP_BODY" | grep -oE "\"$1\":\"[^\"]+\"" | head -1 \
    | sed -E "s/.*\"$1\":\"([^\"]+)\".*/\1/"
}

# The fixture file must exist INSIDE the nginx container, where curl runs.
compose exec -T nginx sh -c 'printf "frappe-framework-patch upload+access sanity\n" > /tmp/fw-upload-test.txt'

echo "== file upload + access sanity ($CI_PROJECT) =="

# 1. Guest upload is rejected: guests cannot upload by default.
status $CMD -X POST -H "$HDR" \
  -F "file=@/tmp/fw-upload-test.txt;filename=fw-guest.txt" -F "is_private=1" \
  http://127.0.0.1:8080/api/method/upload_file
[ "$HTTP_STATUS" = 403 ] && ok "guest upload rejected (403)" || bad "guest upload expected 403, got $HTTP_STATUS: $HTTP_BODY"

# 2. Log in as Administrator.
status $CMD -X POST http://127.0.0.1:8080/api/method/login -H "$HDR" \
  -H "Content-Type: application/x-www-form-urlencoded" -c "$CK" \
  -d "usr=Administrator&pwd=${ADMIN_PASSWORD:-admin}"
if [ "$HTTP_STATUS" = 200 ] && echo "$HTTP_BODY" | grep -q '"Logged In"'; then ok "login Administrator"; else bad "login HTTP $HTTP_STATUS: $HTTP_BODY"; exit 1; fi

# 3. Private upload succeeds when logged in.
status $CMD -X POST -b "$CK" -H "$HDR" \
  -F "file=@/tmp/fw-upload-test.txt;filename=fw-private.txt" -F "is_private=1" \
  http://127.0.0.1:8080/api/method/upload_file
PRIVATE_URL="$(json_field file_url)"
case "$HTTP_STATUS" in
  200) [ -n "$PRIVATE_URL" ] && ok "private upload (200) -> $PRIVATE_URL" || { bad "private upload no file_url: $HTTP_BODY"; exit 1; } ;;
  *) bad "private upload HTTP $HTTP_STATUS: $HTTP_BODY"; exit 1 ;;
esac

# 4. The logged-in user can download the private file.
status $CMD -b "$CK" -H "$HDR" \
  "http://127.0.0.1:8080/api/method/download_file?file_url=$PRIVATE_URL"
case "$HTTP_STATUS" in
  200) ok "private file GET logged in (200)" ;;
  *) bad "private file GET expected 200, got $HTTP_STATUS: $HTTP_BODY"; exit 1 ;;
esac

# 5. A Guest without a token cannot download the private file.
status $CMD -H "$HDR" \
  "http://127.0.0.1:8080/api/method/download_file?file_url=$PRIVATE_URL"
[ "$HTTP_STATUS" = 403 ] && ok "private file GET guest rejected (403)" || bad "private file guest expected 403, got $HTTP_STATUS: $HTTP_BODY"

# 6. Public upload succeeds when logged in; Guest can read it via nginx /files/.
status $CMD -X POST -b "$CK" -H "$HDR" \
  -F "file=@/tmp/fw-upload-test.txt;filename=fw-public.txt" -F "is_private=0" \
  http://127.0.0.1:8080/api/method/upload_file
PUBLIC_URL="$(json_field file_url)"
case "$HTTP_STATUS" in
  200) [ -n "$PUBLIC_URL" ] && ok "public upload (200) -> $PUBLIC_URL" || { bad "public upload no file_url: $HTTP_BODY"; exit 1; } ;;
  *) bad "public upload HTTP $HTTP_STATUS: $HTTP_BODY"; exit 1 ;;
esac

status $CMD -H "$HDR" "http://127.0.0.1:8080$PUBLIC_URL"
[ "$HTTP_STATUS" = 200 ] && ok "public file GET guest (200)" || bad "public file guest expected 200, got $HTTP_STATUS: $HTTP_BODY"

echo
echo "file upload/access result: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "FILE UPLOAD/ACCESS FAILED"; exit 1; }
