#!/bin/bash
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR=$(dirname ${BASE_DIR})
# shellcheck source=./util.sh
source "${BASE_DIR}/utils.sh"
BACKUP_DIR=/opt/jumpserver/db_backup

HOST=$(get_config DB_HOST)
PORT=$(get_config DB_PORT)
USER=$(get_config DB_USER)
PASSWORD=$(get_config DB_PASSWORD)
DATABASE=$(get_config DB_NAME)
DB_FILE=${BACKUP_DIR}/jumpserver-$(date +%F_%T).sql
DB_FILE_ZIP=${DB_FILE}.gz

function main() {
  mkdir -p ${BACKUP_DIR}
  echo "$(gettext 'Backing up')..."
  backup_cmd="mysqldump --host=${HOST} --port=${PORT} --user=${USER} --password=${PASSWORD} ${DATABASE}"
  docker run --rm -i --network=jms_net jumpserver/mysql:5 ${backup_cmd} | gzip > ${DB_FILE_ZIP}

  code="x$?"
  if [[ "$code" != "x0" ]]; then
    log_error "$(gettext 'Backup failed')!"
    rm -f "${DB_FILE_ZIP}"
    exit 1
  else
    log_success "$(gettext 'Backup succeeded! The backup file has been saved to'): ${DB_FILE_ZIP}"
  fi
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
