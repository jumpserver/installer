#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/uninstall"
export JS_CONFIG_DIR="${test_dir}/config"
export JDMC_INSTALL_DIR="${test_dir}/opt/jdmc"
export JDMC_LEGACY_INSTALL_DIR="${test_dir}/opt/kotl"
export JDMC_SYSTEMD_DIRS="${test_dir}/systemd"
mkdir -p "${JS_CONFIG_DIR}" "${JDMC_SYSTEMD_DIRS}/docker.service.d"
cp "${TEST_ROOT}/config-example.txt" "${JS_CONFIG_DIR}/config.txt"

. "${TEST_ROOT}/scripts/8_uninstall.sh"

systemctl_calls=()
systemctl() {
  systemctl_calls+=("$*")
}

main_service="${JDMC_SYSTEMD_DIRS}/${JDMC_SERVICE_NAME}"
mkdir -p "${JDMC_SYSTEMD_DIRS}/multi-user.target.wants"
printf '%s\n' \
  '[Service]' \
  "ExecStart=${JDMC_INSTALL_DIR}/jdmc -config ${JDMC_INSTALL_DIR}/jdmc.yaml" >"${main_service}"
ln -s "${main_service}" "${JDMC_SYSTEMD_DIRS}/multi-user.target.wants/${JDMC_SERVICE_NAME}"
remove_jdmc_main_service_unit "${JDMC_SERVICE_NAME}" "${JDMC_INSTALL_DIR}"
[[ ! -e "${main_service}" ]] || fail 'JDMC main service unit must be removed'
[[ ! -L "${JDMC_SYSTEMD_DIRS}/multi-user.target.wants/${JDMC_SERVICE_NAME}" ]] ||
  fail 'JDMC main service enablement must be removed'
assert_contains "${systemctl_calls[*]}" 'disable --now jdmc.service' \
  'JDMC main service must be stopped and disabled before removal'
assert_contains "${systemctl_calls[*]}" 'daemon-reload' \
  'JDMC main service removal must reload systemd'
printf 'PASS: JDMC main service integration is removed\n'

(
  PROJECT_DIR="${test_dir}/installer"
  mkdir -p "${PROJECT_DIR}"
  export uninstall_events="${test_dir}/events"
  printf 'echo down >>"$uninstall_events"\n' >"${PROJECT_DIR}/jmsctl.sh"
  docker() { [[ "$*" == 'compose version' ]]; }
  sleep() { :; }
  retire_merged_services() {
    echo "$1" >>"${uninstall_events}"
    [[ "$1" != "${fail_action}" ]]
  }
  get_images() { :; }
  read_from_input() { confirm="${file_answer}"; file_answer=n; }
  remove_managed_dir() { echo files >>"${uninstall_events}"; }

  fail_action=stop
  if stop_services; then fail 'uninstall must propagate a legacy container stop failure'; fi
  assert_eq 'stop' "$(cat "${uninstall_events}")"
  fail_action=''
  : >"${uninstall_events}"
  stop_services
  file_answer=n
  remove_jumpserver
  assert_eq $'stop\ndown' "$(cat "${uninstall_events}")" 'declining cleanup must retain the stopped containers and files'
  file_answer=y
  fail_action=remove
  if remove_jumpserver; then fail 'failed container removal must block file deletion'; fi
  assert_eq $'stop\ndown\nremove' "$(cat "${uninstall_events}")"
  file_answer=y
  fail_action=''
  : >"${uninstall_events}"
  remove_jumpserver
  assert_eq $'remove\nfiles' "$(head -n 2 "${uninstall_events}")"
)
printf 'PASS: uninstall retires merged services before deleting their bind-mounted data\n'

calls=()
echo_yellow() { :; }
prepare_jdmc_uninstall() { calls+=(retire); }
stop_services() { calls+=(stop); return 1; }
cleanup_jdmc_host_integration() { calls+=(jdmc); }
installation_log() { calls+=(telemetry); }
remove_jumpserver() { calls+=(jumpserver); }
remove_compose() { calls+=(compose); }
remove_docker() { calls+=(docker); }
remove_jmsctl() { calls+=(jmsctl); }

if main; then
  fail 'Uninstall must fail when services cannot be stopped'
fi
assert_eq 'retire stop' "${calls[*]}" 'Destructive cleanup must not continue after stop failure'

stop_services() { calls+=(stop); }
calls=()
main
assert_eq 'retire stop jdmc telemetry jumpserver compose docker jmsctl' "${calls[*]}" \
  'The management command must be removed only after cleanup succeeds'
printf 'PASS: uninstall failures propagate and cleanup ordering is safe\n'
