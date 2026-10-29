#!/bin/bash
# fix-db-users.sh — Ensure every MariaDB-backed Frappe site has a wildcard-host
# DB user. Pod IPs are ephemeral; a grant pinned to an old pod IP breaks the
# site after the next rollout.
#
# Idempotent: creates/updates '<db_user>'@'%' from site_config.json, grants the
# site database, then removes stale non-wildcard rows for the same user.
#
# Environment variables:
#   DB_ROOT_USER          — MariaDB root user (default: root)
#   DB_HOST               — MariaDB host (default: mariadb)
#   MYSQL_ROOT_PASSWORD   — required
set -euo pipefail

: "${DB_ROOT_USER:=root}"
: "${DB_HOST:=mariadb}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"

SITES_DIR="${SITES_DIR:-/home/frappe/frappe-bench/sites}"

for cmd in jq mysql; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "[fix-db-users] ERROR: required command not found: $cmd" >&2
		exit 1
	}
done

sql_escape() {
	local value=$1
	value=${value//\\/\\\\}
	value=${value//\'/\'\'}
	printf '%s' "$value"
}

mysql_exec() {
	MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
		--protocol=TCP \
		--host="$DB_HOST" \
		--user="$DB_ROOT_USER" \
		--batch --skip-column-names \
		--execute="$1"
}

echo "[fix-db-users] Ensuring DB users have @'%' grants..."

for site_dir in "$SITES_DIR"/*/; do
	site_name=$(basename "$site_dir")
	[ "$site_name" = "assets" ] && continue

	site_config="$site_dir/site_config.json"
	if [ ! -f "$site_config" ]; then
		echo "[fix-db-users] WARNING: config not found for $site_name"
		continue
	fi

	db_type=$(jq -r '.db_type // "mariadb"' "$site_config")
	[ "$db_type" = "mariadb" ] || continue

	db_name=$(jq -r '.db_name // empty' "$site_config")
	db_user=$(jq -r '.db_user // empty' "$site_config")
	db_password=$(jq -r '.db_password // empty' "$site_config")

	if [ -z "$db_name" ] || [ -z "$db_password" ]; then
		echo "[fix-db-users] ERROR: incomplete DB config for $site_name" >&2
		exit 1
	fi
	db_user=${db_user:-$db_name}

	db_name_sql=$(sql_escape "$db_name")
	db_user_sql=$(sql_escape "$db_user")
	db_password_sql=$(sql_escape "$db_password")

	echo "[fix-db-users] Target: $site_name -> ${db_user}@% (${db_name})"

	mysql_exec "
CREATE USER IF NOT EXISTS '${db_user_sql}'@'%' IDENTIFIED BY '${db_password_sql}';
ALTER USER '${db_user_sql}'@'%' IDENTIFIED BY '${db_password_sql}';
GRANT ALL PRIVILEGES ON \`${db_name_sql}\`.* TO '${db_user_sql}'@'%';
FLUSH PRIVILEGES;"

	# Remove stale host-scoped duplicates (typically an old pod IP). The
	# wildcard user above now carries the authoritative site_config password.
	stale_hosts=$(mysql_exec "SELECT host FROM mysql.user WHERE user='${db_user_sql}' AND host <> '%';")
	if [ -n "$stale_hosts" ]; then
		while IFS= read -r stale_host; do
			[ -n "$stale_host" ] || continue
			stale_host_sql=$(sql_escape "$stale_host")
			mysql_exec "DROP USER IF EXISTS '${db_user_sql}'@'${stale_host_sql}'; FLUSH PRIVILEGES;"
			echo "[fix-db-users] Dropped stale grant ${db_user}@${stale_host}"
		done <<< "$stale_hosts"
	fi

	echo "[fix-db-users] OK: $site_name"
done

echo "[fix-db-users] Done."
