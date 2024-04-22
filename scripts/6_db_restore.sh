#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

DB_FILE="$1"
BACKUP_DIR=$(dirname "${DB_FILE}")

function main() {
  echo_warn "$(gettext 'Make sure you have a backup of data, this operation is not reversible')! \n"

  if [[ ! -f "${DB_FILE}" ]]; then
    echo "$(gettext 'file does not exist'): ${DB_FILE}"
    exit 1
  fi

  db_image=$(get_db_images)

  echo "$(gettext 'Start restoring database'): $DB_FILE"

  if ! docker ps | grep jms_ >/dev/null; then
    create_db_ops_env
    flag=1
  fi
  if [[ "${HOST}" == "postgresql" ]]; then
    while [[ "$(docker inspect -f "{{.State.Health.Status}}" jms_postgresql)" != "healthy" ]]; do
      sleep 5s
    done
  fi

  restore_cmd='PGPASSWORD=${DB_PASSWORD} pg_restore --clean --no-owner -U $DB_USER -h $DB_HOST -p $DB_PORT -d $DB_NAME '${DB_FILE}
  if ! docker run --rm --env-file=${CONFIG_FILE} -i --network=jms_net -v "${BACKUP_DIR}:${BACKUP_DIR}" "${db_image}" bash -c "${restore_cmd}"; then
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
