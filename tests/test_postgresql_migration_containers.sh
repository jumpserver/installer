#!/usr/bin/env bash
# Run inside a Linux Bash/Docker CLI test runner with its Docker socket mounted.
# PG18_* inputs are consumed by the sourced migration library.
# shellcheck disable=SC2034
set -Eeuo pipefail
umask 077
docker() {
  if [[ "${PG18_FAIL_RESTORE:-0}" == 1 && "$*" == *"--label jms.pg18.work="* && "$*" == *"--entrypoint bash"* ]]; then return 99; fi
  command docker "$@"
}

if [[ "${RUN_POSTGRESQL_MIGRATION_INTEGRATION:-0}" != 1 && "${PG18_TEST_CHILD:-0}" != 1 ]]; then echo "SKIP: set RUN_POSTGRESQL_MIGRATION_INTEGRATION=1 in a Linux Docker runner"; exit 0; fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ "${PG18_TEST_CHILD:-0}" != 1 ]]; then
  volume="jms-pg18-test-$$-${RANDOM}"
  docker volume create "$volume" >/dev/null
  trap 'docker volume rm "$volume" >/dev/null 2>&1 || true' EXIT
  directory=$(docker volume inspect -f '{{.Mountpoint}}' "$volume")
  runner=$(docker inspect -f '{{.Image}}' "$HOSTNAME")
  docker run --rm -i -e PG18_TEST_CHILD=1 -e "PG18_TEST_ROOT=$directory" -e "PG18_SOURCE_IMAGE=${PG18_SOURCE_IMAGE:-postgres:16.15-bookworm}" \
    -v /var/run/docker.sock:/var/run/docker.sock -v "$volume:$directory" \
    --entrypoint bash "$runner" -c 'mkdir -p "$PG18_TEST_ROOT/src"; tar -C "$PG18_TEST_ROOT/src" -xf -; exec bash "$PG18_TEST_ROOT/src/tests/test_postgresql_migration_containers.sh"' \
    < <(tar -C "$root" -cf - scripts/gists/postgresql-upgrade.sh tests/test_postgresql_migration_containers.sh)
  exit
fi
source "$root/scripts/gists/postgresql-upgrade.sh"
PG18_DATA="$PG18_TEST_ROOT/data"
PG18_CONTAINER="jms-pg18-source-$$-${RANDOM}"
PG18_USER=old_admin PG18_PASSWORD=test-only PG18_PORT=5432
cleanup() { local status=$?; if [[ "$status" != 0 && -f "${PG18_WORK:-}/restore.log" ]]; then tail -n 35 "$PG18_WORK/restore.log" >&2; fi; docker rm -fv "$PG18_CONTAINER" "${PG18_HELPER:-unused}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
mkdir -m 700 "$PG18_DATA"
docker run -d --name "$PG18_CONTAINER" --network none -e POSTGRES_USER=old_admin -e POSTGRES_PASSWORD=test-only \
  -e PGDATA=/var/lib/postgresql/data -v "$PG18_DATA:/var/lib/postgresql/data" "${PG18_SOURCE_IMAGE:-postgres:16.15-bookworm}" >/dev/null
ready=false
for _ in $(seq 1 90); do if pg18_sql 'select 1' >/dev/null 2>&1; then ready=true; break; fi; sleep 1; done
[[ "$ready" == true ]]
source_major=$(cat "$PG18_DATA/PG_VERSION")
pg18_sql "CREATE ROLE application LOGIN PASSWORD 'test-application'; CREATE TABLE public.survivor(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, value text); INSERT INTO survivor(value) VALUES ('中文迁移'),('second'); GRANT SELECT ON survivor TO application; CREATE EXTENSION pgcrypto;" >/dev/null
pg18_sql 'CREATE DATABASE extra;' >/dev/null
before_hash=$(pg18_sql "select rolpassword from pg_authid where rolname='application';")
# Inject a helper failure after a real dump, then retry without touching source data.
PG18_FAIL_RESTORE=1
if pg18_prepare; then echo 'FAIL failed restore was accepted'; exit 1; fi
[[ "$(cat "$PG18_DATA/PG_VERSION")" == "$source_major" && "$(pg18_sql 'select count(*) from survivor;')" == 2 ]]
PG18_FAIL_RESTORE=0
pg18_prepare
[[
 "$(cat "$PG18_WORK/phase")" == ready && "$(cat "$PG18_DATA/PG_VERSION")" == "$source_major" ]]
pg18_prepare # Idempotent staging must not replace its verified snapshot.
# Emulate a crash between the two directory renames during cutover.
docker stop "$PG18_CONTAINER" >/dev/null
pg18_save phase switching
mv "$PG18_DATA" "$PG18_WORK/original"
pg18_cutover
pg18_cutover
[[ "$(cat "$PG18_DATA/PG_VERSION")" == 18 && "$(cat "$PG18_WORK/original/PG_VERSION")" == "$source_major" ]]
docker rm -v "$PG18_CONTAINER" >/dev/null
docker run -d --name "$PG18_CONTAINER" --network none -e PGDATA=/var/lib/postgresql/data \
  -v "$PG18_DATA:/var/lib/postgresql/data" "$PG18_IMAGE" >/dev/null
ready=false
for _ in $(seq 1 90); do if pg18_sql 'select 1' >/dev/null 2>&1; then ready=true; break; fi; sleep 1; done
[[ "$ready" == true ]]
[[ "$(pg18_sql 'select count(*) from survivor;')" == 2 ]]
[[ "$(pg18_sql 'select value from survivor where id=1;')" == 中文迁移 ]]
[[ "$(pg18_sql "insert into survivor(value) values ('after') returning id;")" == 3 ]]
[[ "$(pg18_sql "select rolpassword from pg_authid where rolname='application';")" == "$before_hash" ]]
[[ "$(pg18_sql "select count(*) from pg_database where datname='extra';")" == 1 ]]
[[ "$(pg18_sql "select count(*) from pg_extension where extname='pgcrypto';")" == 1 ]]
[[ "$(pg18_sql "select has_table_privilege('application','survivor','SELECT');")" == t ]]
[[ "$(pg18_sql "select count(*) from pg_roles where rolname='jms_pg18_migration';")" == 0 ]]
printf 'PASS: real PostgreSQL -> 18 preserves all databases, roles/passwords, grants, extension, identity sequence and Unicode; interrupted cutover resumes with original cluster retained\n'
