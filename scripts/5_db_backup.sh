#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

VOLUME_DIR=$(get_config VOLUME_DIR)
BACKUP_DIR="${VOLUME_DIR}/db_backup"
CURRENT_VERSION=$(get_config CURRENT_VERSION)

DB_ENGINE=$(get_config DB_ENGINE "mysql")
DB_HOST=$(get_config DB_HOST)
DB_PORT=$(get_config DB_PORT)
DB_USER=$(get_config DB_USER)
DB_PASSWORD=$(get_config DB_PASSWORD)
DB_NAME=$(get_config DB_NAME)

AUDITS_TABLES=(
  audits_activitylog
  audits_ftplog
  audits_integrationapplicationlog
  audits_operatelog
  audits_passwordchangelog
  audits_userloginlog
  audits_usersession
)

MODE="full"
if [[ $# -gt 0 ]]; then
  case "$1" in
    audit)
      MODE="audit"
      ;;
    *)
      log_error "Usage: $0 [audit]"
      exit 1
      ;;
  esac
fi

function ensure_backup_dir() {
  if [[ ! -d "${BACKUP_DIR}" ]]; then
    mkdir -p "${BACKUP_DIR}"
  fi
}

function prepare_db_env() {
  db_images=$(get_db_images)

  if ! docker ps | grep -w "jms_core" &>/dev/null; then
    create_db_ops_env
    started_db_env=1
  fi

  case "${DB_HOST}" in
    mysql|postgresql)
      while [[ "$(docker inspect -f '{{.State.Health.Status}}' "jms_${DB_HOST}")" != "healthy" ]]; do
        sleep 5s
      done
      ;;
  esac
}

function cleanup_db_env() {
  if [[ "${started_db_env}" -eq 1 ]]; then
    down_db_ops_env
  fi
}

function backup_main_db() {
  case "${DB_ENGINE}" in
    mysql)
      DB_FILE="${BACKUP_DIR}/${DB_NAME}-${CURRENT_VERSION}-$(date +%F_%T).sql"
      backup_cmd='mysqldump --skip-add-locks --skip-lock-tables --single-transaction -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" > "${DB_FILE}"'
      ;;
    postgresql)
      DB_FILE="${BACKUP_DIR}/${DB_NAME}-${CURRENT_VERSION}-$(date +%F_%T).dump"
      backup_cmd='PGPASSWORD="${DB_PASSWORD}" pg_dump --format=custom --no-owner -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" -f "${DB_FILE}"'
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
    "${db_images}" bash -c "${backup_cmd}"; then
    log_error "$(gettext 'Backup failed')!"
    rm -f "${DB_FILE}"
    exit 1
  fi

  if command -v gzip &>/dev/null; then
    if gzip -f "${DB_FILE}"; then
      DB_FILE="${DB_FILE}.gz"
    else
      log_warn "$(gettext 'Backup succeeded, but compression failed')!"
    fi
  fi

  return 0
}

function backup_audits_mysql() {
  local backup_file=$1

  docker run --rm \
    -e MYSQL_PWD="${DB_PASSWORD}" \
    -i --network=jms_net \
    "${db_images}" \
    mysqldump \
      -h"${DB_HOST}" \
      -P"${DB_PORT}" \
      -u"${DB_USER}" \
      --single-transaction \
      --quick \
      --set-gtid-purged=OFF \
      --no-create-info \
      --skip-triggers \
      --insert-ignore \
      --default-character-set=utf8mb4 \
      "${DB_NAME}" \
      "${AUDITS_TABLES[@]}" | gzip > "${backup_file}"
}

function backup_audits_postgresql() {
  local backup_file=$1
  local sql_file=${backup_file%.gz}

  local table_args=()
  local table
  for table in "${AUDITS_TABLES[@]}"; do
    table_args+=("-t" "${table}")
  done

  docker run --rm \
    -e PGPASSWORD="${DB_PASSWORD}" \
    -i --network=jms_net \
    "${db_images}" \
    pg_dump \
      -h "${DB_HOST}" \
      -p "${DB_PORT}" \
      -U "${DB_USER}" \
      -d "${DB_NAME}" \
      --data-only \
      --inserts \
      --no-owner \
      --no-privileges \
      "${table_args[@]}" | sed '/^INSERT INTO / s/;[[:space:]]*$/ ON CONFLICT DO NOTHING;/' > "${sql_file}" || return 1

  gzip -f "${sql_file}" || return 1
}

function backup_audits() {
  case "${DB_ENGINE}" in
    mysql)
      AUDIT_FILE="${BACKUP_DIR}/audits_${CURRENT_VERSION}_$(date +%F_%H%M%S).sql.gz"
      if ! backup_audits_mysql "${AUDIT_FILE}"; then
        rm -f "${AUDIT_FILE}"
        log_error "$(gettext 'Backup failed')!"
        exit 1
      fi
      ;;
    postgresql)
      AUDIT_FILE="${BACKUP_DIR}/audits_${CURRENT_VERSION}_$(date +%F_%H%M%S).sql.gz"
      if ! backup_audits_postgresql "${AUDIT_FILE}"; then
        rm -f "${AUDIT_FILE}"
        rm -f "${AUDIT_FILE%.gz}"
        log_error "$(gettext 'Backup failed')!"
        exit 1
      fi
      ;;
    *)
      log_error "$(gettext 'Invalid DB Engine selection')!"
      exit 1
      ;;
  esac

  if [[ ! -s "${AUDIT_FILE}" ]]; then
    log_error "$(gettext 'Backup file is empty')!"
    rm -f "${AUDIT_FILE}"
    exit 1
  fi

  return 0
}

function main() {
  started_db_env=0
  ensure_backup_dir

  echo "$(gettext 'Backing up')..."
  prepare_db_env

  case "${MODE}" in
    full)
      if ! backup_main_db; then
        cleanup_db_env
        exit 1
      fi
      log_success "$(gettext 'Backup succeeded! The backup file has been saved to'): ${DB_FILE}"
      ;;
    audit)
      if ! backup_audits; then
        cleanup_db_env
        exit 1
      fi
      log_success "$(gettext 'Backup succeeded! The backup file has been saved to'): ${AUDIT_FILE}"
      ;;
  esac

  cleanup_db_env
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi