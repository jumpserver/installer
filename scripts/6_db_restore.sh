#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

DB_FILE="$1"
BACKUP_DIR=$(dirname "${DB_FILE}")

DB_HOST=$(get_config DB_HOST)

function main() {
  echo_warn "$(gettext 'Make sure you have a backup of data, this operation is not reversible')! \n"

  if [[ ! -f "${DB_FILE}" ]]; then
    echo "$(gettext 'file does not exist'): ${DB_FILE}"
    exit 1
  fi

  mysql_images=$(get_mysql_images)

  echo "$(gettext 'Start restoring database'): $DB_FILE"

  if ! docker ps | grep -w "jms_core" &>/dev/null; then
    create_db_ops_env
    flag=1
  fi

  if [[ "${DB_HOST}" == "mysql" ]]; then
    while [[ "$(docker inspect -f "{{.State.Health.Status}}" jms_mysql)" != "healthy" ]]; do
      sleep 5s
    done
  fi

  restore_cmd='mysql -h$DB_HOST -P$DB_PORT -u$DB_USER -p"$DB_PASSWORD" $DB_NAME < '${DB_FILE}
  if ! docker run --rm --env-file=${CONFIG_FILE} -i --network=jms_net -v "${BACKUP_DIR}:${BACKUP_DIR}" "${mysql_images}" bash -c "${restore_cmd}"; then
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
