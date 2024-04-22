#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

VOLUME_DIR=$(get_config VOLUME_DIR)
BACKUP_DIR="${VOLUME_DIR}/db_backup"
CURRENT_VERSION=$(get_config CURRENT_VERSION)

DATABASE=$(get_config DB_NAME)
DB_FILE=${BACKUP_DIR}/${DATABASE}-${CURRENT_VERSION}-$(date +%F_%T).pgdump

function main() {
  if [[ ! -d ${BACKUP_DIR} ]]; then
    mkdir -p ${BACKUP_DIR}
  fi
  echo "$(gettext 'Backing up')..."

  db_image=$(get_db_images)

  if ! docker ps | grep jms_ >/dev/null; then
    create_db_ops_env
    flag=1
  fi
  if [[ "${HOST}" == "postgresql" ]]; then
    while [[ "$(docker inspect -f "{{.State.Health.Status}}" jms_postgresql)" != "healthy" ]]; do
      sleep 5s
    done
  fi

  backup_cmd='PGPASSWORD=${DB_PASSWORD} pg_dump --format=custom --no-owner -U $DB_USER -h $DB_HOST -p $DB_PORT -d "$DB_NAME" -f '${DB_FILE}
  if ! docker run --rm --env-file=${CONFIG_FILE} -i --network=jms_net -v "${BACKUP_DIR}:${BACKUP_DIR}" "${db_image}" bash -c "${backup_cmd}"; then
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
