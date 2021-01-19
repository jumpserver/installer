#!/bin/bash
# coding: utf-8

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

DB_FILE="$1"

function main() {
  echo "$(gettext -s 'Start restoring database'): $DB_FILE"
  restore_cmd="mysql --host=${HOST} --port=${PORT} --user=${USER} --password=${PASSWORD} ${DATABASE}"

  if [[ ! -f "${DB_FILE}" ]]; then
    echo "$(gettext -s 'file does not exist'): ${DB_FILE}"
    exit 2
  fi

  if [[ "${DB_FILE}" == *".gz" ]]; then
    gunzip <${DB_FILE} | docker run --rm -i --network=jms_net jumpserver/mysql:5 ${restore_cmd}
  else
    docker run --rm -i --network=jms_net jumpserver/mysql:5 $restore_cmd <"${DB_FILE}"
  fi
  code="x$?"
  if [[ "$code" != "x0" ]]; then
    log_error "$(gettext -s 'Database recovery failed. Please check whether the database file is complete or try to recover manually')!"
    exit 1
  else
    log_success "$(gettext -s 'Database recovered successfully')!"
  fi
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  if [[ -z "$1" ]]; then
    log_error "$(gettext -s 'Format error')！Usage './jmsctl.sh restore_db DB_Backup_file '"
    exit 1
  fi
  if [[ ! -f $1 ]];then
    echo "$(gettext -s 'The backup file does not exist'): $1"
    exit 2
  fi
  main
fi
