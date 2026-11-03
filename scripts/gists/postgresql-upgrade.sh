#!/usr/bin/env bash
# Shared by the standalone installer and JDMC's coordinated maintenance worker.
# Callers must fence every application writer before prepare/cutover, and keep
# those fences until the replacement database and application are verified.
PG18_IMAGE=postgres:18.6-bookworm

pg18_error() { printf '[postgresql-upgrade] %s\n' "$*" >&2; return 1; }
pg18_save() {
  local name=$1 value=$2 tmp
  tmp=$(mktemp "${PG18_WORK}/.${name}.XXXXXX") || return 1
  printf '%s\n' "${value}" >"${tmp}" && chmod 600 "${tmp}" && sync "${tmp}" &&
    mv -f -- "${tmp}" "${PG18_WORK}/${name}" && sync -f "${PG18_WORK}"
}

pg18_paths() {
  [[ "${PG18_DATA}" == /* && "${PG18_DATA}" != / && ! -L "${PG18_DATA}" ]] || return 1
  [[ "$(readlink -f "$(dirname "${PG18_DATA}")")/$(basename "${PG18_DATA}")" == "${PG18_DATA}" ]] ||
    pg18_error 'PostgreSQL migration requires a canonical data directory' || return 1
  PG18_WORK="${PG18_DATA}.upgrade18"
  [[ ! -L "${PG18_WORK}" ]] || return 1
  if [[ ! -e "${PG18_WORK}" ]]; then mkdir -m 700 "${PG18_WORK}" || return 1; fi
  [[ "$(stat -Lc '%u:%a' "${PG18_WORK}")" == 0:700 ]] || return 1
  PG18_HELPER="jms-pg18-$(printf %s "${PG18_DATA}" | sha256sum | cut -c1-20)"
}

pg18_sql() {
  # Password travels through stdin, never through an argument or a journal.
  printf '%s\n' "${PG18_PASSWORD}" | docker exec -i -e PGCONNECT_TIMEOUT=10 "${PG18_CONTAINER}" sh -ceu '
    IFS= read -r PGPASSWORD; export PGPASSWORD
    exec psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$1" -U "$2" -d postgres -tAqc "$3"
  ' sh "${PG18_PORT}" "${PG18_USER}" "$1"
}

pg18_remove_stale_helper() {
  if docker inspect "${PG18_HELPER}" >/dev/null 2>&1; then
    [[ "$(docker inspect -f '{{index .Config.Labels "jms.pg18.work"}}' "${PG18_HELPER}")" == "${PG18_WORK}" ]] || return 1
    docker rm -f -v "${PG18_HELPER}" >/dev/null || return 1
  fi
}

pg18_preflight() {
  local version tablespaces settings bytes free
  docker image inspect "${PG18_IMAGE}" >/dev/null || return 1
  [[ -f "${PG18_DATA}/PG_VERSION" && ! -L "${PG18_DATA}/PG_VERSION" ]] || return 1
  version=$(cat "${PG18_DATA}/PG_VERSION") || return 1
  [[ "${version}" =~ ^1[0-7]$ ]] || pg18_error "Unsupported migration source: ${version}" || return 1
  [[ "$(pg18_sql "select current_setting('server_version_num')::int/10000;")" == "${version}" ]] || return 1
  [[ "$(pg18_sql 'select rolsuper from pg_roles where rolname=current_user;')" == t ]] ||
    pg18_error 'A verified local PostgreSQL administrator is required for a full-cluster migration' || return 1
  [[ "${PG18_ALLOW_STANDBY:-0}" == 1 || "$(pg18_sql 'select pg_is_in_recovery();')" == f ]] || return 1
  tablespaces=$(pg18_sql "select count(*) from pg_tablespace where spcname not in ('pg_default','pg_global');") || return 1
  [[ "${tablespaces}" == 0 ]] || pg18_error 'Custom tablespaces require a dedicated migration plan' || return 1
  settings=$(pg18_sql "select current_setting('data_directory')='/var/lib/postgresql/data' and current_setting('config_file')='/var/lib/postgresql/data/postgresql.conf' and current_setting('hba_file')='/var/lib/postgresql/data/pg_hba.conf' and current_setting('ident_file')='/var/lib/postgresql/data/pg_ident.conf' and current_setting('ssl')='off' and not exists (select 1 from pg_file_settings where sourcefile not in ('/var/lib/postgresql/data/postgresql.conf','/var/lib/postgresql/data/postgresql.auto.conf'));") || return 1
  [[ "${settings}" == t ]] || pg18_error 'External PostgreSQL configuration/SSL files require a dedicated migration plan' || return 1
  [[ "$(pg18_sql "select (select count(*) from pg_subscription)=0 and (select count(*) from pg_prepared_xacts)=0 and not exists (select 1 from pg_replication_slots where slot_type='logical' or slot_name<>'jdmc_standby');")" == t ]] ||
    pg18_error 'Logical replication, custom replication slots or prepared transactions require a dedicated migration plan' || return 1
  if (( version >= 15 )); then
    [[ "$(pg18_sql "select datlocprovider='c' from pg_database where datname='template0';")" == t ]] ||
      pg18_error 'A non-libc template cluster requires a dedicated locale migration plan' || return 1
  fi
  # Reject symlinked WAL/configuration and user-defined storage outside PGDATA.
  [[ -z "$(find "${PG18_DATA}" -type l -print -quit)" ]] || pg18_error 'Symlinked PostgreSQL storage is not supported by the automatic migration' || return 1
  [[ "$(pg18_sql "select count(*) from pg_database where datname='jms_pg18_migration';")" == 0 ]] || return 1
  bytes=$(du -sk "${PG18_DATA}" | awk '{print $1}') || return 1
  free=$(df -Pk "$(dirname "${PG18_DATA}")" | awk 'END {print $4}') || return 1
  [[ "${bytes}" =~ ^[0-9]+$ && "${free}" =~ ^[0-9]+$ ]] || return 1
  (( free > bytes * 3 + 1048576 )) || pg18_error 'Insufficient free space for the original cluster, logical backup and new cluster' || return 1
}

pg18_prepare() {
  local phase locale
  pg18_paths || return 1
  phase=$(cat "${PG18_WORK}/phase" 2>/dev/null || true)
  case "${phase}" in ready|switching|switched|complete) return 0 ;; ''|reserved|preparing) ;; *) return 1 ;; esac
  pg18_preflight || return 1
  # A previous crashed helper must never keep writing the staging directory.
  pg18_remove_stale_helper || return 1
  pg18_save source-version "$(cat "${PG18_DATA}/PG_VERSION")" || return 1
  pg18_save source-image "$(docker inspect -f '{{.Config.Image}}' "${PG18_CONTAINER}")" || return 1
  pg18_save source-identity "$(stat -Lc '%d:%i' "${PG18_DATA}")" || return 1
  pg18_save target-image-id "$(docker image inspect -f '{{.Id}}' "${PG18_IMAGE}")" || return 1
  locale=$(pg18_sql "select pg_encoding_to_char(encoding)||E'\\t'||datcollate||E'\\t'||datctype from pg_database where datname='template0';") || return 1
  pg18_save locale "${locale}" || return 1
  pg18_save bootstrap-role "$(pg18_sql 'select rolname from pg_authid where oid=10;')" || return 1
  pg18_save bootstrap-quoted "$(pg18_sql 'select quote_ident(rolname) from pg_authid where oid=10;')" || return 1
  pg18_save phase preparing || return 1
  printf '[postgresql-upgrade] Exporting all databases and roles; original data remains at %s\n' "${PG18_DATA}" >&2
  if ! printf '%s\n' "${PG18_PASSWORD}" | docker run --rm -i --name "${PG18_HELPER}" --label "jms.pg18.work=${PG18_WORK}" --network "container:${PG18_CONTAINER}" \
      --entrypoint sh "${PG18_IMAGE}" -ceu '
      IFS= read -r PGPASSWORD; export PGPASSWORD PGCONNECT_TIMEOUT=10
      exec pg_dumpall -h 127.0.0.1 -p "$1" -U "$2" --clean --if-exists
    ' sh "${PG18_PORT}" "${PG18_USER}" >"${PG18_WORK}/cluster.partial.sql"; then return 1; fi
  [[ -s "${PG18_WORK}/cluster.partial.sql" ]] || return 1
  chmod 600 "${PG18_WORK}/cluster.partial.sql" && sync "${PG18_WORK}/cluster.partial.sql" &&
    mv -f "${PG18_WORK}/cluster.partial.sql" "${PG18_WORK}/cluster.sql" || return 1
  # Only the isolated, transaction-owned target is disposable on a retry.
  [[ ! -L "${PG18_WORK}/target" ]] || return 1
  rm -rf -- "${PG18_WORK}/target" || return 1
  mkdir -m 700 "${PG18_WORK}/target" || return 1
  if ! docker run --rm -i --name "${PG18_HELPER}" --label "jms.pg18.work=${PG18_WORK}" --network none \
      -e PGDATA=/var/lib/postgresql/data -v "${PG18_WORK}:/migration" -v "${PG18_WORK}/target:/var/lib/postgresql/data" -v "${PG18_DATA}:/source:ro" --entrypoint bash "${PG18_IMAGE}" -s -- "${PG18_USER}" \
      >"${PG18_WORK}/restore.log" 2>&1 <<'PG18_RESTORE'
set -Eeuo pipefail
IFS=$'\t' read -r encoding collate ctype </migration/locale
chown postgres:postgres /var/lib/postgresql/data
gosu postgres initdb -D /var/lib/postgresql/data -U "$(cat /migration/bootstrap-role)" --encoding="$encoding" --lc-collate="$collate" --lc-ctype="$ctype" --auth-local=trust --auth-host=scram-sha-256
export PGHOST=/tmp PGPORT=5432 PGUSER="$(cat /migration/bootstrap-role)" PGDATABASE=template1
gosu postgres pg_ctl -D /var/lib/postgresql/data -l /var/lib/postgresql/data/restore-server.log -o "-c listen_addresses='' -c unix_socket_directories='/tmp'" -w start
trap 'gosu postgres pg_ctl -D /var/lib/postgresql/data -m immediate -w stop >/dev/null 2>&1 || true' EXIT
gosu postgres createdb --template=template0 jms_pg18_migration
export PGDATABASE=jms_pg18_migration
# OID 10 owns PostgreSQL's system objects and cannot be dropped/reassigned.
# Retain that exact source identity; apply its final privileges only after restore.
awk -v role="$(cat /migration/bootstrap-quoted)" '
  $0 == "DROP ROLE " role ";" || $0 == "DROP ROLE IF EXISTS " role ";" || $0 == "CREATE ROLE " role ";" {next}
  index($0,"ALTER ROLE " role " WITH ")==1 {print > "/migration/bootstrap-final.sql"; next}
  {print}
' /migration/cluster.sql > /migration/restore.sql
gosu postgres psql -X -v ON_ERROR_STOP=1 < /migration/restore.sql
export PGDATABASE=postgres
PGUSER="$1" gosu postgres dropdb jms_pg18_migration
PGUSER="$1" gosu postgres vacuumdb --all --analyze-in-stages
gosu postgres psql -X -v ON_ERROR_STOP=1 < /migration/bootstrap-final.sql
gosu postgres pg_ctl -D /var/lib/postgresql/data -m fast -w stop
trap - EXIT
for file in postgresql.conf postgresql.auto.conf pg_hba.conf pg_ident.conf; do
  [[ -f /source/$file && ! -L /source/$file ]]
  cp -p "/source/$file" "/var/lib/postgresql/data/$file"
done
chown -R postgres:postgres /var/lib/postgresql/data
# PostgreSQL validates inherited settings before any production cutover.
gosu postgres postgres -D /var/lib/postgresql/data -C data_directory >/dev/null
printf 'local all all trust\n' >/tmp/migration-hba.conf
chmod 644 /tmp/migration-hba.conf
gosu postgres pg_ctl -D /var/lib/postgresql/data -l /var/lib/postgresql/data/validation-server.log -o "-c listen_addresses='' -c unix_socket_directories='/tmp' -c hba_file=/tmp/migration-hba.conf -c synchronous_standby_names=''" -w start
trap 'gosu postgres pg_ctl -D /var/lib/postgresql/data -m immediate -w stop >/dev/null 2>&1 || true' EXIT
PGUSER="$1" gosu postgres psql -X -v ON_ERROR_STOP=1 -c 'SELECT 1;' >/dev/null
gosu postgres pg_ctl -D /var/lib/postgresql/data -m fast -w stop
trap - EXIT
sync -f /migration
PG18_RESTORE
  then pg18_error "Restore failed; original data is intact. Private log: ${PG18_WORK}/restore.log"; return 1; fi
  [[ "$(cat "${PG18_WORK}/target/PG_VERSION")" == 18 ]] || return 1
  pg18_save phase ready
}

pg18_cutover() {
  local phase
  pg18_paths || return 1
  phase=$(cat "${PG18_WORK}/phase") || return 1
  case "${phase}" in complete|switched) [[ "$(cat "${PG18_DATA}/PG_VERSION")" == 18 ]]; return $? ;; ready|switching) ;; *) return 1 ;; esac
  [[ "$(docker image inspect -f '{{.Id}}' "${PG18_IMAGE}")" == "$(cat "${PG18_WORK}/target-image-id")" ]] || return 1
  docker stop "${PG18_CONTAINER}" >/dev/null || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "${PG18_CONTAINER}")" == false ]] || return 1
  # The 18 image also traverses its declared parent volume after dropping UID.
  # Preserve existing read/write permissions; grant only directory traversal.
  pg18_save parent-mode "$(stat -Lc '%a' "$(dirname "${PG18_DATA}")")" || return 1
  chmod a+x "$(dirname "${PG18_DATA}")" || return 1
  pg18_save phase switching || return 1
  if [[ ! -e "${PG18_WORK}/original" ]]; then
    [[ "$(stat -Lc '%d:%i' "${PG18_DATA}")" == "$(cat "${PG18_WORK}/source-identity")" ]] || return 1
    sync -f "${PG18_DATA}" && mv -- "${PG18_DATA}" "${PG18_WORK}/original" && sync -f "${PG18_WORK}" || return 1
  fi
  [[ ! -L "${PG18_WORK}/original" && "$(stat -Lc '%d:%i' "${PG18_WORK}/original")" == "$(cat "${PG18_WORK}/source-identity")" ]] || return 1
  if [[ ! -e "${PG18_DATA}" ]]; then mv -- "${PG18_WORK}/target" "${PG18_DATA}" && sync -f "${PG18_WORK}" || return 1; fi
  [[ ! -L "${PG18_DATA}" && "$(cat "${PG18_DATA}/PG_VERSION")" == 18 ]] || return 1
  pg18_save phase switched
}
