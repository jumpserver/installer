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

function get_postgresql_reset_sql() {
  cat <<'SQL'
SELECT set_config('jumpserver.restore_schema', :'restore_schema', true);
DO $reset_schema$
DECLARE
  schema_oid oid;
  item record;
BEGIN
  SELECT oid INTO STRICT schema_oid FROM pg_catalog.pg_namespace
  WHERE nspname = current_setting('jumpserver.restore_schema');

  -- Drop all objects of each kind together so internal foreign keys and
  -- view dependencies are handled by PostgreSQL. RESTRICT protects objects
  -- outside this schema; an error rolls back the entire restore transaction.
  FOR item IN
    SELECT kind, string_agg(identity, ', ') AS identities
    FROM (
      SELECT CASE c.relkind
               WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW'
               WHEN 'S' THEN 'SEQUENCE' WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE'
             END AS kind, format('%I.%I', n.nspname, c.relname) AS identity
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relnamespace = schema_oid AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
      UNION ALL
      SELECT CASE p.prokind WHEN 'a' THEN 'AGGREGATE'
               WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
             format('%I.%I(%s)', n.nspname, p.proname,
                    pg_catalog.pg_get_function_identity_arguments(p.oid))
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
      WHERE p.pronamespace = schema_oid
      UNION ALL
      SELECT 'TYPE', format('%I.%I', n.nspname, t.typname)
      FROM pg_catalog.pg_type t
      JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
      LEFT JOIN pg_catalog.pg_class c ON c.oid = t.typrelid
      WHERE t.typnamespace = schema_oid
        AND (t.typtype IN ('d', 'e', 'r', 'm') OR c.relkind = 'c'
             OR (t.typtype = 'b' AND t.typelem = 0))
    ) objects
    GROUP BY kind
    ORDER BY array_position(ARRAY['VIEW', 'MATERIALIZED VIEW', 'TABLE', 'FOREIGN TABLE', 'SEQUENCE',
                                  'AGGREGATE', 'PROCEDURE', 'FUNCTION', 'TYPE'], kind)
  LOOP
    EXECUTE format('DROP %s IF EXISTS %s RESTRICT', item.kind, item.identities);
  END LOOP;
END
$reset_schema$;
SQL
}

function main() {
  local reset_sql=""
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
      restore_file="${DB_FILE}"
      tmp_restore_file=""
      if [[ "${DB_FILE}" == *.gz ]]; then
        tmp_restore_file=$(mktemp "${BACKUP_DIR}/.pg_restore.XXXXXX")
        if ! gzip -dc "${DB_FILE}" > "${tmp_restore_file}"; then
          log_error "$(gettext 'Failed to decompress backup file')!"
          rm -f "${tmp_restore_file}"
          exit 1
        fi
        restore_file="${tmp_restore_file}"
      fi

      pg_magic=$(dd if="${restore_file}" bs=1 count=5 2>/dev/null)
      if [[ "${pg_magic}" == "PGDMP" ]]; then
        if ! restore_schema=$(get_postgresql_schema) ||
          ! reset_sql=$(get_postgresql_reset_sql); then
          [[ -n "${tmp_restore_file}" ]] && rm -f "${tmp_restore_file}"
          exit 1
        fi
      fi

      restore_cmd='
        magic=$(dd if="${RESTORE_FILE}" bs=1 count=5 2>/dev/null)
        if [[ "${magic}" == "PGDMP" ]]; then
          umask 077
          restore_dir=$(mktemp -d) || exit 1
          trap '\''rm -rf "${restore_dir}"'\'' EXIT
          # Finish extracting the selected schema before touching the database.
          pg_restore --schema="${RESTORE_SCHEMA}" --strict-names --no-owner \
            --file="${restore_dir}/restore.sql" "${RESTORE_FILE}" || exit 1
          PGPASSWORD="${DB_PASSWORD}" psql -X -v ON_ERROR_STOP=1 \
            --single-transaction -v restore_schema="${RESTORE_SCHEMA}" \
            -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" \
            -f - -f "${restore_dir}/restore.sql"
        else
          PGPASSWORD="${DB_PASSWORD}" psql -q -v ON_ERROR_STOP=1 -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" < "${RESTORE_FILE}" >/dev/null
        fi
      '
      ;;
    *)
      log_error "$(gettext 'Invalid DB Engine selection')!"
      exit 1
      ;;
  esac

  docker_env=(
    --env "DB_HOST=${DB_HOST}" --env "DB_PORT=${DB_PORT}" --env "DB_USER=${DB_USER}"
    --env "DB_PASSWORD=${DB_PASSWORD}" --env "DB_NAME=${DB_NAME}" --env "DB_FILE=${DB_FILE}"
  )
  if [[ "${DB_ENGINE}" == "postgresql" ]]; then
    docker_env+=(--env "RESTORE_FILE=${restore_file}" --env "RESTORE_SCHEMA=${restore_schema}")
  fi

  if ! docker run --rm "${docker_env[@]}" \
    -i --network=jms_net \
    -v "${BACKUP_DIR}:${BACKUP_DIR}" \
    "${db_images}" bash -c "${restore_cmd}" <<< "${reset_sql}"; then
    [[ -n "${tmp_restore_file}" ]] && rm -f "${tmp_restore_file}"
    log_error "$(gettext 'Database recovery failed. Please check whether the database file is complete or try to recover manually')!"
    exit 1
  else
    [[ -n "${tmp_restore_file}" ]] && rm -f "${tmp_restore_file}"
    log_success "$(gettext 'Database recovered successfully')!"
    run_post_restore
  fi

  if [[ -n "$flag" ]]; then
    down_db_ops_env
    unset flag
  fi
}

function run_post_restore() {
  echo "$(gettext 'Updating database schema')..."
  if ! perform_db_migrations; then
    log_warn "$(gettext 'Failed to change the table structure')!"
  fi
}

function stop_jms_core() {
  if docker ps | grep -w "jms_core" &>/dev/null; then
    docker stop jms_core &>/dev/null || true
    docker stop jms_celery &>/dev/null || true
  fi
}

function start_jms_core() {
  docker start jms_core &>/dev/null || true
  docker start jms_celery &>/dev/null || true
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
  stop_jms_core
  main
  start_jms_core
fi
