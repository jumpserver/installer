#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

VOLUME_DIR=$(get_config VOLUME_DIR)
BACKUP_DIR="${VOLUME_DIR}/db_backup"
CURRENT_VERSION=$(get_config CURRENT_VERSION)

HOST=$(get_config DB_HOST)
PORT=$(get_config DB_PORT)
USER=$(get_config DB_USER)
PASSWORD=$(get_config DB_PASSWORD)
DATABASE=$(get_config DB_NAME)
DB_FILE=${BACKUP_DIR}/${DATABASE}-${CURRENT_VERSION}-$(date +%F_%T).sql

function main() {
  if [[ ! -d ${BACKUP_DIR} ]]; then
    mkdir -p ${BACKUP_DIR}
  fi
  echo "$(gettext 'Backing up')..."

  mysql_images=$(get_mysql_images)

  if ! docker ps | grep jms_ >/dev/null; then
    create_db_ops_env
    flag=1
  fi
  if [[ "${HOST}" == "mysql" ]]; then
    while [[ "$(docker inspect -f "{{.State.Health.Status}}" jms_mysql)" != "healthy" ]]; do
      sleep 5s
    done
  fi

  backup_cmd="mysqldump --skip-add-locks --skip-lock-tables --single-transaction --host=${HOST} --port=${PORT} --user=${USER} --password=${PASSWORD} ${DATABASE}"
  if ! docker run --rm -i --network=jms_net "${mysql_images}" ${backup_cmd} > "${DB_FILE}"; then
    log_error "$(gettext 'Backup failed')!"
    rm -f "${DB_FILE}"
    exit 1
  else
    log_success "$(gettext 'Backup succeeded! The backup file has been saved to'): ${DB_FILE}"
  fi

  if [[ -n "$flag" ]]; then
    down_db_ops_env
    unset flag
  fi
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
