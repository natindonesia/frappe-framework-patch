#!/bin/bash
# fix-db-users.sh — Post-bootstrap loop that creates '@'%'' users for every existing Frappe site.
# Runs inside the init container after bench setup.
# Requires: jq, mysql client, MYSQL_ROOT_PASSWORD env var, activated bench venv.
# Environment variables:
#   DB_ROOT_USER  — MariaDB root user (default: root)
#   DB_HOST       — MariaDB host (default: mariadb)

: "${DB_ROOT_USER:=root}"
: "${DB_HOST:=mariadb}"

echo "[fix-db-users] Ensuring DB users have @'%' grants for horizontal scaling..."
echo ""

for CURRENT_SITE_NAME in $(cd /home/frappe/frappe-bench/sites && ls -d */ 2>/dev/null | sed 's|/||g' | tr -d '\r'); do

    if [ -z "$CURRENT_SITE_NAME" ] || [ "$CURRENT_SITE_NAME" = "assets" ]; then continue; fi

    SITE_CONFIG_PATH="/home/frappe/frappe-bench/sites/${CURRENT_SITE_NAME}/site_config.json"

    if [ -f "${SITE_CONFIG_PATH}" ]; then
        DB_NAME_CREATED=$(jq -r .db_name "${SITE_CONFIG_PATH}" | tr -d '\r')
        DB_PASSWORD_CREATED=$(jq -r .db_password "${SITE_CONFIG_PATH}" | tr -d '\r')
        DB_USER_CREATED=${DB_NAME_CREATED}

        echo "[fix-db-users] Target DB: ${DB_NAME_CREATED}  User: ${DB_USER_CREATED}"

        SQL_COMMAND="CREATE USER IF NOT EXISTS '${DB_USER_CREATED}'@'%' IDENTIFIED BY '${DB_PASSWORD_CREATED}';
GRANT ALL PRIVILEGES ON \`${DB_NAME_CREATED}\`.* TO '${DB_USER_CREATED}'@'%';
FLUSH PRIVILEGES;"

        echo "[fix-db-users] Executing SQL..."

        mysql -u "${DB_ROOT_USER}" -p"${MYSQL_ROOT_PASSWORD}" -h "${DB_HOST}" -e "${SQL_COMMAND}"

        if [ $? -eq 0 ]; then
            echo "[fix-db-users] SUCCESS: Grants updated for ${CURRENT_SITE_NAME}"
        else
            echo "[fix-db-users] ERROR: MySQL command failed for ${CURRENT_SITE_NAME}"
            echo "[fix-db-users] Failed SQL: ${SQL_COMMAND}"
        fi
    else
        echo "[fix-db-users] WARNING: Config not found for ${CURRENT_SITE_NAME}"
    fi

    echo ""
done

echo "[fix-db-users] Done."