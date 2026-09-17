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
