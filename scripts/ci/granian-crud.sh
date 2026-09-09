#!/usr/bin/env bash
# Full CRUD smoke through Granian + nginx using the perf.sh ToDo shape.
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
CK=/tmp/crud_cookie.$$
LF=/tmp/crud_log.$$
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

echo "== CRUD smoke (granian + nginx + ToDo) =="
status $CMD -X POST http://127.0.0.1:8080/api/method/login -H "$HDR" -H "Content-Type: application/x-www-form-urlencoded" -c "$CK" -d "usr=Administrator&pwd=${ADMIN_PASSWORD:-admin}"
if [ "$HTTP_STATUS" = 200 ] && echo "$HTTP_BODY" | grep -q '"Logged In"'; then ok "login Administrator"; else bad "login HTTP $HTTP_STATUS: $HTTP_BODY"; exit 1; fi
DESC="crud-$(date +%s)"
status $CMD -b "$CK" -H "$HDR" -H "Content-Type: application/json" -d "{\"data\":{\"doctype\":\"ToDo\",\"description\":\"$DESC\",\"status\":\"Open\"}}" http://127.0.0.1:8080/api/resource/ToDo
NAME="$(printf '%s' "$HTTP_BODY" | grep -oE '"name":"[^"]+"' | head -1 | sed -E 's/.*"name":"([^"]+)".*/\1/')"
case "$HTTP_STATUS" in
  200|201) [ -n "$NAME" ] && ok "create ToDo -> $NAME" || { bad "create no name: $HTTP_BODY"; exit 1; } ;;
  *) bad "create HTTP $HTTP_STATUS: $HTTP_BODY"; exit 1; ;;
esac
status $CMD -b "$CK" -H "$HDR" "http://127.0.0.1:8080/api/resource/ToDo/$NAME"
case "$HTTP_STATUS" in
  200) printf '%s' "$HTTP_BODY" | grep -q "$DESC" && ok "read item matches" || { bad "read body missing desc: $HTTP_BODY"; exit 1; } ;;
  *) bad "read HTTP $HTTP_STATUS: $HTTP_BODY"; exit 1; ;;
esac
status $CMD -b "$CK" -H "$HDR" "http://127.0.0.1:8080/api/resource/ToDo?limit_page_length=20"
case "$HTTP_STATUS" in
  200) printf '%s' "$HTTP_BODY" | grep -q "$NAME" && ok "list contains item" || { bad "list missing item: $HTTP_BODY"; exit 1; } ;;
  *) bad "list HTTP $HTTP_STATUS: $HTTP_BODY"; exit 1; ;;
esac
status $CMD -X PUT -b "$CK" -H "$HDR" -H "Content-Type: application/json" -d "{\"data\":{\"status\":\"Closed\"}}" "http://127.0.0.1:8080/api/resource/ToDo/$NAME"
[ "$HTTP_STATUS" = 200 ] && ok "update item (status -> Closed)" || { bad "update HTTP $HTTP_STATUS: $HTTP_BODY"; exit 1; }
status $CMD -X DELETE -b "$CK" -H "$HDR" "http://127.0.0.1:8080/api/resource/ToDo/$NAME"
case "$HTTP_STATUS" in
  200|202) ok "delete item (cleanup)" ;;
  *) bad "delete HTTP $HTTP_STATUS: $HTTP_BODY"; exit 1; ;;
esac
echo
echo "CRUD result: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "CRUD FAILED"; exit 1; }