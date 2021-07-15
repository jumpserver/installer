#!/bin/bash
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"
BACKUP_DIR=/opt/jumpserver/db_backup
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

  if ! docker network ls | grep jms_net >/dev/null; then
    check_container_if_need
    flag=1
  fi

  backup_cmd="mysqldump --host=${HOST} --port=${PORT} --user=${USER} --password=${PASSWORD} ${DATABASE}"
  if ! docker run --rm -i --network=jms_net "${mysql_images}" ${backup_cmd} > "${DB_FILE}"; then
    log_error "$(gettext 'Backup failed')!"
    rm -f "${DB_FILE}"
    exit 1
  else
    log_success "$(gettext 'Backup succeeded! The backup file has been saved to'): ${DB_FILE}"
  fi

  if [[ "$flag" ]]; then
    docker stop jms_redis >/dev/null 2>&1
    docker rm jms_redis >/dev/null 2>&1
    unset flag
  fi
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
