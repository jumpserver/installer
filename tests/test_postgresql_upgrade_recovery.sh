#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "${TEST_ROOT}/scripts/gists/postgresql-upgrade-standalone.sh"

PG18_WORK="${TEST_TMP_ROOT}/pg18-recovery"
mkdir -p "${PG18_WORK}"
PG18_UPGRADE_ACTIVE=1
PG18_IMAGE=postgres:test
calls="${PG18_WORK}/calls"
enabled='core web celery kael ansible-executor future-service'
failed_container=''
get_enabled_services() { printf '%s\n' "${enabled}"; }
get_config() { printf '%s\n' "${2:-}"; }
get_docker_compose_cmd_line() { printf '%s\n' mock_compose; }
prepare_services_for_start() { printf 'prepare %s\n' "$*" >>"${calls}"; }
mock_compose() { printf 'compose %s\n' "$*" >>"${calls}"; }
log_error() { printf '%s\n' "$*" >&2; }
log_success() { :; }
pg18_save() { printf '%s\n' "$2" >"${PG18_WORK}/$1"; }
docker() {
  printf 'docker %s\n' "$*" >>"${calls}"
  if [[ "$1" == inspect && "${2:-}" == -f ]]; then
    if [[ "${4:-}" == "${failed_container}" ]]; then printf 'exited\n'; else printf 'healthy\n'; fi
  fi
}

cat >"${PG18_WORK}/writers" <<'WRITERS'
/jms_core true always 0 core
/jms_web true unless-stopped 0 web
/jms_celery false on-failure 3 celery
WRITERS
: >"${calls}"
complete_internal_postgresql_upgrade
calls_text=$(cat "${calls}")
assert_contains "${calls_text}" 'prepare core web kael ansible-executor future-service' 'recovery must prepare enabled new services'
assert_contains "${calls_text}" 'compose up -d --no-deps --force-recreate kael ansible-executor future-service' 'new services must start from Compose with their restart policies'
assert_contains "${calls_text}" 'compose up -d core web' 'previously running services must be restored'
assert_contains "${calls_text}" 'docker update --restart=on-failure:3 /jms_celery' 'stopped service restart policy must be preserved'
assert_contains "${calls_text}" 'jms_ansible_executor' 'executor container name must be mapped correctly'
[[ "${calls_text}" != *'compose up -d core web celery'* ]] || fail 'previously stopped services must remain stopped'
[[ "${calls_text}" != *'disabled-service'* ]] || fail 'disabled services must not start'
assert_eq complete "$(cat "${PG18_WORK}/phase")" 'all recovered services must be healthy before completion'
printf 'PASS: recovery starts and checks new enabled services while preserving recorded intent\n'

# Retry after an interrupted attempt: recreate new containers, including kael,
# and do not mark migration complete if a newly introduced service is unhealthy.
printf 'switched\n' >"${PG18_WORK}/phase"
failed_container=jms_kael
: >"${calls}"
if complete_internal_postgresql_upgrade; then fail 'failed new service must prevent completion'; fi
assert_eq switched "$(cat "${PG18_WORK}/phase")" 'unhealthy new service must leave migration pending'
assert_contains "$(cat "${calls}")" 'compose up -d --no-deps --force-recreate kael' 'retry must recreate newly introduced services'
printf 'PASS: failure in a new service keeps recovery pending\n'

# With no previously running services, upgrade must not start an idle deployment.
failed_container=''
printf '/jms_core false always 0 core\n' >"${PG18_WORK}/writers"
: >"${calls}"
complete_internal_postgresql_upgrade
[[ "$(cat "${calls}")" != *'compose up'* ]] || fail 'idle deployment must stay stopped'
assert_eq complete "$(cat "${PG18_WORK}/phase")" 'idle deployment recovery should complete'
printf 'PASS: idle deployment remains stopped\n'

# A release with no new enabled service must not issue an empty Compose command.
printf '/jms_core true always 0 core\n' >"${PG18_WORK}/writers"
enabled=core
: >"${calls}"
complete_internal_postgresql_upgrade
[[ "$(cat "${calls}")" != *'--force-recreate'* ]] || fail 'no new services should require recreation'
printf 'PASS: recovery handles a release without new services\n'

# An explicitly stopped kael in the saved snapshot must not be treated as new.
cat >"${PG18_WORK}/writers" <<'WRITERS'
/jms_core true always 0 core
/jms_kael false always 0 kael
WRITERS
enabled='core kael'
: >"${calls}"
complete_internal_postgresql_upgrade
calls_text=$(cat "${calls}")
[[ "${calls_text}" != *'--force-recreate'* && "${calls_text}" != *'compose up -d core kael'* ]] || fail 'recorded stopped kael must remain stopped'
printf 'PASS: a recorded stopped kael remains stopped\n'
