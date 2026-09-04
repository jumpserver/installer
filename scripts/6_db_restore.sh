#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

DB_FILE="$1"
BACKUP_DIR=$(dirname "${DB_FILE}")

DB_ENGINE=$(get_config DB_ENGINE "mysql")
DB_HOST=$(get_config DB_HOST)
DB_PORT=$(get_config DB_PORT)
DB_USER=$(get_config DB_USER)
DB_PASSWORD=$(get_config DB_PASSWORD)
DB_NAME=$(get_config DB_NAME)
RESTORE_TMP_FILE=""
CORE_WAS_RUNNING=0
CELERY_WAS_RUNNING=0
started_db_env=0

function restore_mysql() {
  local restore_cmd='
        if [[ "${DB_FILE}" == *.gz ]]; then
          gzip -dc "${DB_FILE}" | MYSQL_PWD="${DB_PASSWORD}" mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" "${DB_NAME}"
        else
          MYSQL_PWD="${DB_PASSWORD}" mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" "${DB_NAME}" < "${DB_FILE}"
        fi
      '
  local docker_env=(
    --env "DB_HOST=${DB_HOST}" --env "DB_PORT=${DB_PORT}" --env "DB_USER=${DB_USER}"
    --env "DB_PASSWORD=${DB_PASSWORD}" --env "DB_NAME=${DB_NAME}" --env "DB_FILE=${DB_FILE}"
  )

  docker run --rm "${docker_env[@]}" \
    -i --network=jms_net \
    -v "${BACKUP_DIR}:${BACKUP_DIR}" \
    "${db_images}" bash -c "${restore_cmd}"
}

function restore_postgresql() {
  local restore_file="${DB_FILE}"
  if [[ "${DB_FILE}" == *.gz ]]; then
    RESTORE_TMP_FILE=$(mktemp "${BACKUP_DIR}/.pg_restore.XXXXXX") || return 1
    if ! gzip -dc "${DB_FILE}" > "${RESTORE_TMP_FILE}"; then
      log_error "$(gettext 'Failed to decompress backup file')!"
      rm -f "${RESTORE_TMP_FILE}"
      RESTORE_TMP_FILE=""
      return 1
    fi
    restore_file="${RESTORE_TMP_FILE}"
  fi

  local pg_magic
  pg_magic=$(dd if="${restore_file}" bs=1 count=5 2>/dev/null)
  if [[ "${pg_magic}" == "PGDMP" ]]; then
    echo "$(gettext 'Resetting database schema before restore')..."
  fi

  local restore_cmd='
        reset_pg_public_schema() {
          PGPASSWORD="${DB_PASSWORD}" psql -v ON_ERROR_STOP=1 -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" \
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();" \
            -c "DROP SCHEMA IF EXISTS public CASCADE;" \
            -c "CREATE SCHEMA public;" \
            -c "GRANT ALL ON SCHEMA public TO public;" \
            -c "GRANT ALL ON SCHEMA public TO \"${DB_USER}\";"
        }

        magic=$(dd if="${RESTORE_FILE}" bs=1 count=5 2>/dev/null)
        if [[ "${magic}" == "PGDMP" ]]; then
          reset_pg_public_schema
          PGPASSWORD="${DB_PASSWORD}" pg_restore --disable-triggers --no-owner --exit-on-error -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" "${RESTORE_FILE}"
        else
          PGPASSWORD="${DB_PASSWORD}" psql -q -v ON_ERROR_STOP=1 -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" < "${RESTORE_FILE}" >/dev/null
        fi
      '
  local docker_env=(
    --env "DB_HOST=${DB_HOST}" --env "DB_PORT=${DB_PORT}" --env "DB_USER=${DB_USER}"
    --env "DB_PASSWORD=${DB_PASSWORD}" --env "DB_NAME=${DB_NAME}"
    --env "RESTORE_FILE=${restore_file}"
  )

  docker run --rm "${docker_env[@]}" \
    -i --network=jms_net \
    -v "${BACKUP_DIR}:${BACKUP_DIR}" \
    "${db_images}" bash -c "${restore_cmd}"
  local restore_status=$?

  if [[ -n "${RESTORE_TMP_FILE}" ]]; then
    rm -f "${RESTORE_TMP_FILE}"
    RESTORE_TMP_FILE=""
  fi
  return ${restore_status}
}

function restore_database() {
  case "${DB_ENGINE}" in
    mysql)
      restore_mysql
      ;;
    postgresql)
      restore_postgresql
      ;;
    *)
      log_error "$(gettext 'Invalid DB Engine selection')!"
      return 1
      ;;
  esac
}

function main() {
  echo_warn "$(gettext 'Make sure you have a backup of data, this operation is not reversible')! \n"

  if [[ ! -f "${DB_FILE}" ]]; then
    echo "$(gettext 'file does not exist'): ${DB_FILE}"
    return 1
  fi

  DB_FILE="$(cd "$(dirname "${DB_FILE}")" && pwd -P)/$(basename "${DB_FILE}")"
  BACKUP_DIR=$(dirname "${DB_FILE}")

  db_images=$(get_db_images)

  echo "$(gettext 'Start restoring database'): $DB_FILE"

  if ! docker ps | grep -w "jms_core" &>/dev/null; then
    create_db_ops_env || return 1
    started_db_env=1
  fi
  case "${DB_HOST}" in
    mysql|postgresql)
      wait_container_healthy "jms_${DB_HOST}" || return 1
      ;;
  esac

  if ! restore_database; then
    log_error "$(gettext 'Database recovery failed. Please check whether the database file is complete or try to recover manually')!"
    return 1
  fi

  if ! run_post_restore; then
    return 1
  fi
  log_success "$(gettext 'Database recovered successfully')!"
}

function run_post_restore() {
  echo "$(gettext 'Updating database schema')..."
  if ! perform_db_migrations; then
    log_error "$(gettext 'Failed to change the table structure')!"
    return 1
  fi
}

function stop_jms_core() {
  if [[ "$(docker inspect -f '{{.State.Running}}' jms_core 2>/dev/null)" == "true" ]]; then
    CORE_WAS_RUNNING=1
    docker stop jms_core &>/dev/null || return 1
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' jms_celery 2>/dev/null)" == "true" ]]; then
    CELERY_WAS_RUNNING=1
    docker stop jms_celery &>/dev/null || return 1
  fi
}

function start_jms_core() {
  local cmd
  local -a services=()

  [[ "${CORE_WAS_RUNNING}" == "1" ]] && services+=(core)
  [[ "${CELERY_WAS_RUNNING}" == "1" ]] && services+=(celery)
  [[ ${#services[@]} -gt 0 ]] || return 0

  cmd=$(get_docker_compose_cmd_line)
  ${cmd} up -d "${services[@]}"
}

function cleanup_restore() {
  local status=$?

  if [[ -n "${RESTORE_TMP_FILE}" ]]; then
    rm -f "${RESTORE_TMP_FILE}"
    RESTORE_TMP_FILE=""
  fi
  if [[ "${started_db_env}" == "1" ]]; then
    down_db_ops_env || true
    started_db_env=0
  fi
  if ! start_jms_core; then
    log_error "Failed to restore the services that were running before database recovery"
    [[ "${status}" == "0" ]] && status=1
  fi
  trap - EXIT
  exit "${status}"
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  if [[ -z "$1" ]]; then
    log_error "$(gettext 'Format error')！Usage './jmsctl.sh restore_db DB_Backup_file'"
    exit 1
  fi
  if [[ ! -f $1 ]]; then
    echo "$(gettext 'The backup file does not exist'): $1"
    exit 1
  fi
  trap cleanup_restore EXIT
  stop_jms_core || exit 1
  main
  exit $?
fi
