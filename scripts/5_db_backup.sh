#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

VOLUME_DIR=$(get_config VOLUME_DIR)
BACKUP_DIR="${VOLUME_DIR}/db_backup"
CURRENT_VERSION=$(get_config CURRENT_VERSION)

DB_ENGINE=$(get_config DB_ENGINE "mysql")
DB_HOST=$(get_config DB_HOST)
DB_NAME=$(get_config DB_NAME)

function main() {
  if [[ ! -d ${BACKUP_DIR} ]]; then
    mkdir -p ${BACKUP_DIR}
  fi
  echo "$(gettext 'Backing up')..."

  db_images=$(get_db_images)

  if ! docker ps | grep jms_&>/dev/null; then
    create_db_ops_env
    flag=1
  fi
  case "${DB_HOST}" in
    mysql|postgresql)
      while [[ "$(docker inspect -f "{{.State.Health.Status}}" jms_${DB_HOST})" != "healthy" ]]; do
        sleep 5s
      done
      ;;
  esac

  case "${DB_ENGINE}" in
    mysql)
      DB_FILE=${BACKUP_DIR}/${DB_NAME}-${CURRENT_VERSION}-$(date +%F_%T).sql
      backup_cmd='mysqldump --skip-add-locks --skip-lock-tables --single-transaction -h$DB_HOST -P$DB_PORT -u$DB_USER -p"$DB_PASSWORD" $DB_NAME > '${DB_FILE}
      ;;
    postgresql)
      DB_FILE=${BACKUP_DIR}/${DB_NAME}-${CURRENT_VERSION}-$(date +%F_%T).dump
      backup_cmd='PGPASSWORD=${DB_PASSWORD} pg_dump --format=custom --no-owner -U $DB_USER -h $DB_HOST -p $DB_PORT -d "$DB_NAME" -f '${DB_FILE}
      ;;
    *)
      log_error "$(gettext 'Invalid DB Engine selection')!"
      exit 1
      ;;
  esac

  if ! docker run --rm --env-file=${CONFIG_FILE} -i --network=jms_net -v "${BACKUP_DIR}:${BACKUP_DIR}" "${db_images}" bash -c "${backup_cmd}"; then
    log_error "$(gettext 'Backup failed')!"
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