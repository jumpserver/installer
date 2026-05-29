#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

DB_FILE="$1"
AUDIT_FILE="${2:-}"
BACKUP_DIR=$(dirname "${DB_FILE}")

DB_ENGINE=$(get_config DB_ENGINE "mysql")
DB_HOST=$(get_config DB_HOST)
DB_PORT=$(get_config DB_PORT)
DB_USER=$(get_config DB_USER)
DB_PASSWORD=$(get_config DB_PASSWORD)
DB_NAME=$(get_config DB_NAME)

function main() {
  echo_warn "$(gettext 'Make sure you have a backup of data, this operation is not reversible')! \n"

  if [[ ! -f "${DB_FILE}" ]]; then
    echo "$(gettext 'file does not exist'): ${DB_FILE}"
    exit 1
  fi

  db_images=$(get_db_images)

  echo "$(gettext 'Start restoring database'): $DB_FILE"

  if ! docker ps | grep -w "jms_core" &>/dev/null; then
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
      restore_cmd='
        if [[ "${DB_FILE}" == *.gz ]]; then
          gzip -dc "${DB_FILE}" | mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}"
        else
          mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" < "${DB_FILE}"
        fi
      '
      ;;
    postgresql)
      pg_magic=""
      if [[ "${DB_FILE}" == *.gz ]]; then
        pg_magic=$(gzip -dc "${DB_FILE}" 2>/dev/null | dd bs=1 count=5 2>/dev/null)
      else
        pg_magic=$(dd if="${DB_FILE}" bs=1 count=5 2>/dev/null)
      fi
      if [[ "${pg_magic}" == "PGDMP" ]]; then
        echo "$(gettext 'Resetting database schema before restore')..."
      fi
      restore_cmd='
        reset_pg_public_schema() {
          PGPASSWORD="${DB_PASSWORD}" psql -v ON_ERROR_STOP=1 -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" \
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();" \
            -c "DROP SCHEMA IF EXISTS public CASCADE;" \
            -c "CREATE SCHEMA public;" \
            -c "GRANT ALL ON SCHEMA public TO public;" \
            -c "GRANT ALL ON SCHEMA public TO \"${DB_USER}\";"
        }

        restore_pg_file() {
          local input_file=$1
          local magic

          magic=$(dd if="${input_file}" bs=1 count=5 2>/dev/null)
          if [[ "${magic}" == "PGDMP" ]]; then
            reset_pg_public_schema
            PGPASSWORD="${DB_PASSWORD}" pg_restore --no-owner --exit-on-error -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" "${input_file}"
          else
            PGPASSWORD="${DB_PASSWORD}" psql -q -v ON_ERROR_STOP=1 -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" < "${input_file}" >/dev/null
          fi
        }

        if [[ "${DB_FILE}" == *.gz ]]; then
          tmp_restore_file="${DB_FILE%.gz}"
          gzip -dc "${DB_FILE}" > "${tmp_restore_file}" && restore_pg_file "${tmp_restore_file}"
          rc=$?
          rm -f "${tmp_restore_file}"
          exit ${rc}
        else
          restore_pg_file "${DB_FILE}"
        fi
      '
      ;;
    *)
      log_error "$(gettext 'Invalid DB Engine selection')!"
      exit 1
      ;;
  esac

  if ! docker run --rm \
    --env DB_HOST="${DB_HOST}" --env DB_PORT="${DB_PORT}" --env DB_USER="${DB_USER}" --env DB_PASSWORD="${DB_PASSWORD}" --env DB_NAME="${DB_NAME}" --env DB_FILE="${DB_FILE}" \
    -i --network=jms_net \
    -v "${BACKUP_DIR}:${BACKUP_DIR}" \
    "${db_images}" bash -c "${restore_cmd}"; then
    log_error "$(gettext 'Database recovery failed. Please check whether the database file is complete or try to recover manually')!"
    exit 1
  else
    log_success "$(gettext 'Database recovered successfully')!"
    run_post_restore
  fi

  if [[ -n "$flag" ]]; then
    down_db_ops_env
    unset flag
  fi
}

function restore_audit_backup() {
  local audit_file=$1

  if [[ ! -f "${audit_file}" ]]; then
    log_error "$(gettext 'The backup file does not exist'): ${audit_file}"
    return 1
  fi

  echo "$(gettext 'Restoring audit tables from'): ${audit_file}"
  local audit_dir
  audit_dir=$(dirname "${audit_file}")

  local audit_restore_cmd
  case "${DB_ENGINE}" in
    mysql)
      audit_restore_cmd='
        if [[ "${AUDIT_FILE}" == *.gz ]]; then
          gzip -dc "${AUDIT_FILE}" | mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}"
        else
          mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" < "${AUDIT_FILE}"
        fi
      '
      ;;
    postgresql)
      audit_restore_cmd='
        if [[ "${AUDIT_FILE}" == *.gz ]]; then
          gzip -dc "${AUDIT_FILE}" | psql -q -v ON_ERROR_STOP=1 -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" >/dev/null
        else
          psql -q -v ON_ERROR_STOP=1 -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" < "${AUDIT_FILE}" >/dev/null
        fi
      '
      ;;
    *)
      log_error "$(gettext 'Invalid DB Engine selection')!"
      return 1
      ;;
  esac

  if ! docker run --rm \
    --env DB_HOST="${DB_HOST}" --env DB_PORT="${DB_PORT}" --env DB_USER="${DB_USER}" --env DB_PASSWORD="${DB_PASSWORD}" --env DB_NAME="${DB_NAME}" --env AUDIT_FILE="${audit_file}" \
    -i --network=jms_net \
    -v "${audit_dir}:${audit_dir}" \
    "${db_images}" bash -c "${audit_restore_cmd}"; then
    log_error "$(gettext 'Audit tables recovery failed')!"
    return 1
  fi

  log_success "$(gettext 'Audit tables recovered successfully')!"
  return 0
}

function run_post_restore() {
  echo "$(gettext 'Updating database schema')..."
  if ! perform_db_migrations; then
    log_warn "$(gettext 'Failed to change the table structure')!"
  fi

  if [[ -n "${AUDIT_FILE}" ]]; then
    restore_audit_backup "${AUDIT_FILE}" || exit 1
  fi
}

function stop_jms_core() {
  if docker ps | grep -w "jms_core" &>/dev/null; then
    docker stop jms_core &>/dev/null || true
  fi
}

function start_jms_core() {
  docker start jms_core &>/dev/null || true
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  if [[ -z "$1" ]]; then
    log_error "$(gettext 'Format error')！Usage './jmsctl.sh restore_db DB_Backup_file [audit_backup_file]'"
    exit 1
  fi
  if [[ ! -f $1 ]]; then
    echo "$(gettext 'The backup file does not exist'): $1"
    exit 1
  fi
  stop_jms_core
  main
  start_jms_core
fi