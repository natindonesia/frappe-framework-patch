#!/bin/bash
# init.sh — Frappe bench init container entrypoint.
# Creates/reconfigures the site and ensures DB user grants for horizontal scaling.
set -e
set -x

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
  if [ -f "/scripts/fix-db-users.sh" ]; then
    bash /scripts/fix-db-users.sh
  fi
else
  if [ -f "/scripts/fix-db-users.sh" ]; then
    bash /scripts/fix-db-users.sh
  fi
  bench --site all migrate
fi


# Seed baked assets.json onto the shared sites volume. Skipped when the
# destination is read-only (e.g. the composed deployment image-mounts the
# manifest over sites/assets/assets.json directly, and init runs with the
# same read-only mount).
if [ -f "/opt/defaults/assets.json" ]; then
  mkdir -p sites/assets
  dest=sites/assets/assets.json
  if [ -w "$dest" ] || { [ ! -e "$dest" ] && [ -w sites/assets ]; }; then
    cp /opt/defaults/assets.json "$dest"
  else
    echo "[init] $dest is read-only - skipping baked assets.json copy"
  fi
fi

