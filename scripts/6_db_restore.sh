#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

HOST=$(get_config DB_HOST)
PORT=$(get_config DB_PORT)
USER=$(get_config DB_USER)
PASSWORD=$(get_config DB_PASSWORD)
DATABASE=$(get_config DB_NAME)

DB_FILE="$1"

function main() {
  echo_warn "$(gettext 'Make sure you have a backup of data, this operation is not reversible')! \n"
  restore_cmd="mysql --host=${HOST} --port=${PORT} --user=${USER} --password=${PASSWORD} ${DATABASE}"

  if [[ ! -f "${DB_FILE}" ]]; then
    echo "$(gettext 'file does not exist'): ${DB_FILE}"
    exit 1
  fi

  mysql_images=$(get_mysql_images)

  echo "$(gettext 'Start restoring database'): $DB_FILE"

  if ! docker ps | grep jms_ >/dev/null; then
    create_db_ops_env
    flag=1
  fi
  if [[ "${HOST}" == "mysql" ]]; then
    while [[ "$(docker inspect -f "{{.State.Health.Status}}" jms_mysql)" != "healthy" ]]; do
      sleep 5s
    done
  fi

  if ! docker run --rm -i --network=jms_net "${mysql_images}" $restore_cmd <"${DB_FILE}"; then
    log_error "$(gettext 'Database recovery failed. Please check whether the database file is complete or try to recover manually')!"
    exit 1
  else
    log_success "$(gettext 'Database recovered successfully')!"
  fi

  if [[ -n "$flag" ]]; then
    down_db_ops_env
    unset flag
  fi
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  if [[ -z "$1" ]]; then
    log_error "$(gettext 'Format error')！Usage './jmsctl.sh restore_db DB_Backup_file '"
    exit 1
  fi
  if [[ ! -f $1 ]]; then
    echo "$(gettext 'The backup file does not exist'): $1"
    exit 1
  fi
  main
fi
