#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "${TEST_ROOT}/scripts/gists/common.sh"
. "${TEST_ROOT}/scripts/gists/service.sh"

test_dir="${TEST_TMP_ROOT}/compose-failure"
mkdir -p "${test_dir}"

# Exercise the real migration guard and logger without contacting Docker.
postgresql_upgrade_pending() { return 0; }
PG18_UPGRADE_ACTIVE=0
status=0
compose_cmd=$(get_docker_compose_cmd_line 2>"${test_dir}/guard.stderr") || status=$?
assert_eq 1 "${status}" 'a pending migration must reject command generation'
assert_eq '' "${compose_cmd}" 'error logs must not enter the captured command'
assert_contains "$(cat "${test_dir}/guard.stderr")" '[ERROR] PostgreSQL migration is pending'
printf 'PASS: Compose generation errors preserve the diagnostic on stderr\n'

# Run the real entry points without errexit: command generation can fail before
# producing a command, or after producing partial output. Neither may execute.
fixture="${test_dir}/installer"
mkdir -p "${fixture}/scripts" "${fixture}/compose"
cp "${TEST_ROOT}/jmsctl.sh" "${fixture}/jmsctl.sh"
cp "${TEST_ROOT}/scripts/6_db_restore.sh" "${fixture}/scripts/6_db_restore.sh"
: >"${test_dir}/config.txt"
export COMPOSE_FAILURE_ROOT="${test_dir}"
export COMPOSE_FAILURE_SOURCE="${TEST_ROOT}"
cat >"${fixture}/scripts/utils.sh" <<'EOF'
. "${COMPOSE_FAILURE_SOURCE}/scripts/gists/common.sh"
CONFIG_FILE="${COMPOSE_FAILURE_ROOT}/config.txt"
UNCHECK_DEPENDENCIES=1
gen_safe_config() { :; }
get_config() { printf '%s\n' "${2:-}"; }
get_config_or_env() { printf '%s\n' "${!1:-1}"; }
set_openbao() { :; }
configure_jdmc() { :; }
stop_disabled_video_worker() { :; }
retire_merged_services() {
  printf 'legacy %s\n' "$*" >>"${COMPOSE_FAILURE_ROOT}/events"
  return "${LEGACY_STOP_STATUS:-0}"
}
prepare_services_for_start() { :; }
get_docker_compose_cmd_line() {
  local count
  count=$(cat "${COMPOSE_FAILURE_ROOT}/count")
  count=$((count + 1))
  printf '%s\n' "${count}" >"${COMPOSE_FAILURE_ROOT}/count"
  if [[ "${count}" == "${COMPOSE_FAIL_AT}" ]]; then
    log_error 'Compose generation failed'
    printf '%s' "${COMPOSE_FAILURE_OUTPUT}"
    return 1
  fi
  printf 'unexpected_compose\n'
}
unexpected_compose() {
  printf 'compose %s\n' "$*" >>"${COMPOSE_FAILURE_ROOT}/events"
  return "${COMPOSE_COMMAND_STATUS:-0}"
}
remove_stopped_openbao_init_container() { printf 'cleanup\n' >>"${COMPOSE_FAILURE_ROOT}/events"; }
ensure_current_installer_link() { printf 'link\n' >>"${COMPOSE_FAILURE_ROOT}/events"; }
start_jdmc() { printf 'jdmc\n' >>"${COMPOSE_FAILURE_ROOT}/events"; }
stop_jdmc() { :; }
EOF

for COMPOSE_FAILURE_OUTPUT in '' unexpected_compose; do
  export COMPOSE_FAILURE_OUTPUT
  for scenario in main start stop restore; do
    printf '0\n' >"${test_dir}/count"
    : >"${test_dir}/events"
    export COMPOSE_FAIL_AT=2
    status=0
    expected_events=''
    case "${scenario}" in
      main)
        export COMPOSE_FAIL_AT=1
        bash +e +u "${fixture}/jmsctl.sh" start >"${test_dir}/stdout" 2>"${test_dir}/stderr" || status=$?
        ;;
      start)
        bash +e +u "${fixture}/jmsctl.sh" start >"${test_dir}/stdout" 2>"${test_dir}/stderr" || status=$?
        ;;
      stop)
        expected_events='legacy stop'
        bash +e +u "${fixture}/jmsctl.sh" stop ignore_db >"${test_dir}/stdout" 2>"${test_dir}/stderr" || status=$?
        ;;
      restore)
        export COMPOSE_FAIL_AT=1
        bash +e +u -c '
          . "$1/scripts/6_db_restore.sh" unused-backup
          CORE_WAS_RUNNING=1
          start_jms_core
        ' bash "${fixture}" >"${test_dir}/stdout" 2>"${test_dir}/stderr" || status=$?
        ;;
    esac
    assert_eq 1 "${status}" "${scenario} must propagate command generation failure"
    assert_eq "${expected_events}" "$(cat "${test_dir}/events")" "${scenario} must not execute a failed Compose command"
    assert_eq '' "$(cat "${test_dir}/stdout")" "${scenario} must not leak partial commands"
    diagnostic=$(cat "${test_dir}/stderr")
    assert_contains "${diagnostic}" '[ERROR] Compose generation failed'
    [[ "${diagnostic}" != *'command not found'* ]] || fail "${scenario} must preserve the original error"
  done
done
printf 'PASS: management and restore entry points stop on Compose generation failures\n'

export COMPOSE_FAIL_AT=0 ANSIBLE_EXECUTOR_ENABLED=0 KOKO_ENABLED=1
run_jmsctl() {
  : >"${test_dir}/events"
  bash +e +u "${fixture}/jmsctl.sh" "$@" >"${test_dir}/stdout"
}
startup_events() {
  run_jmsctl "$@" || return 1
  grep -E '^(legacy |compose up )' "${test_dir}/events"
}
assert_eq $'legacy stop koko\nlegacy stop razor\ncompose up -d' "$(startup_events start)"
assert_eq $'legacy stop koko\nlegacy stop razor\ncompose up -d' "$(startup_events restart)"
assert_eq $'legacy stop koko\ncompose up -d koko' "$(startup_events restart koko)"
assert_eq $'legacy stop razor\ncompose up -d razor' "$(startup_events restart razor)"
assert_eq 'compose up -d web' "$(startup_events restart web)"
assert_eq $'legacy stop razor\ncompose up -d' "$(KOKO_ENABLED=0 startup_events start)"
assert_eq $'legacy stop koko\ncompose up -d' "$(RAZOR_ENABLED=0 startup_events start)"
assert_eq $'legacy stop koko\ncompose up -d' "$(USE_XPACK=0 startup_events start)"
if LEGACY_STOP_STATUS=1 startup_events start; then
  fail 'KoKo must not start when a legacy container failed to stop'
fi
assert_eq 'legacy stop koko' "$(cat "${test_dir}/events")"
if LEGACY_STOP_STATUS=1 startup_events restart razor; then
  fail 'Razor must not start when a legacy container failed to stop'
fi
printf 'PASS: startup stops legacy services before KoKo and Razor and propagates stop failures\n'

for target in '' ignore_db --skip-jdmc; do
  KOKO_ENABLED=0 run_jmsctl stop "${target}"
  assert_eq $'legacy stop\ncompose down -v' "$(cat "${test_dir}/events")"
done
run_jmsctl stop koko
assert_eq $'legacy stop koko\ncompose stop koko\ncompose rm -f koko' "$(cat "${test_dir}/events")"
run_jmsctl stop razor
assert_eq $'legacy stop razor\ncompose stop razor\ncompose rm -f razor' "$(cat "${test_dir}/events")"
run_jmsctl stop web
assert_eq $'compose stop web\ncompose rm -f web' "$(cat "${test_dir}/events")"
run_jmsctl stop jdmc
assert_eq '' "$(cat "${test_dir}/events")"
if LEGACY_STOP_STATUS=1 run_jmsctl stop; then
  fail 'shutdown must report failure if a legacy container cannot stop'
fi
assert_eq 'legacy stop' "$(cat "${test_dir}/events")"
printf 'PASS: stop shuts down legacy services before Compose and respects the requested service\n'

status=0
COMPOSE_COMMAND_STATUS=127 run_jmsctl stop || status=$?
assert_eq 127 "${status}" 'a missing Compose command must still be reported for the rest of the stack'
assert_eq $'legacy stop\ncompose down -v' "$(cat "${test_dir}/events")"
rm "${test_dir}/config.txt"
for target in chen kael lion magnus nec; do
  run_jmsctl stop "${target}"
  assert_eq "legacy stop ${target}" "$(cat "${test_dir}/events")"
done
if run_jmsctl stop; then fail 'a partial shutdown must not report success'; fi
assert_eq 'legacy stop' "$(cat "${test_dir}/events")"
if LEGACY_STOP_STATUS=1 run_jmsctl stop chen; then fail 'a targeted Docker stop failure must propagate'; fi
printf 'PASS: retired containers can be stopped even without installer configuration or Compose\n'
