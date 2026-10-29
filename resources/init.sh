#!/bin/bash
# init.sh — Frappe bench init container entrypoint.
# Creates/reconfigures the site and ensures DB user grants for horizontal scaling.
set -euo pipefail

: "${SITE_NAME:?SITE_NAME is required}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"

FIX_DB_USERS=/scripts/fix-db-users.sh
if [ ! -x "$FIX_DB_USERS" ]; then
  echo "[init] ERROR: $FIX_DB_USERS missing or not executable" >&2
  exit 1
fi

cd /home/frappe/frappe-bench
. env/bin/activate

# Bench-wide config must be set BEFORE new-site so the site is created
# against the right DB/redis endpoints.
bench set-mariadb-host mariadb
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

# Bench-wide app list derived from what is actually in the bench
# (the bench contains only frappe; other apps may or may not be present).
ls -1 apps > sites/apps.txt

if [ ! -d "sites/${SITE_NAME}" ]; then
  # --mariadb-user-host-login-scope='%' replaces the deprecated
  # --no-mariadb-socket: it creates the DB user with a wildcard host grant
  # so the horizontally-scaled web/worker replicas can all connect.
  bench new-site "${SITE_NAME}" \
    --force \
    --mariadb-root-username root \
    --mariadb-root-password "${MYSQL_ROOT_PASSWORD}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --mariadb-user-host-login-scope='%'

  # Only attempt app installs for apps that are actually in the bench.
  if [ -d apps/crm ]; then
    bench --site "${SITE_NAME}" install-app crm
  fi

  bench --site "${SITE_NAME}" set-config developer_mode 1
  bash "$FIX_DB_USERS"
else
  bash "$FIX_DB_USERS"
  bench --site all migrate
fi

