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

docker_unit="${JDMC_SYSTEMD_DIRS}/docker.service.d/jdmc.conf"
printf '%s\n' \
  '[Service]' \
  'ExecStartPre=/usr/local/bin/keep-this-hook' \
  "ExecStartPre=${JDMC_DOCKER_FIREWALL_SCRIPT}" >"${docker_unit}"

systemctl_calls=()
systemctl() {
  systemctl_calls+=("$*")
}

cleanup_stale_jdmc_docker_hooks
if grep -Fq "${JDMC_DOCKER_FIREWALL_SCRIPT}" "${docker_unit}"; then
  fail 'Missing JDMC firewall scripts must be removed from Docker units'
fi
assert_contains "$(cat "${docker_unit}")" 'ExecStartPre=/usr/local/bin/keep-this-hook' \
  'Unrelated Docker hooks must be preserved'
assert_eq 'daemon-reload' "${systemctl_calls[0]}" 'Docker hook cleanup must reload systemd'
assert_eq 'reset-failed docker' "${systemctl_calls[1]}" 'Docker hook cleanup must clear the failed start limit'

ha_service="${JDMC_SYSTEMD_DIRS}/${JDMC_HA_FIREWALL_SERVICE_NAME}"
ha_dropin="${JDMC_SYSTEMD_DIRS}/docker.service.d/${JDMC_DOCKER_HA_DROPIN_NAME}"
main_service="${JDMC_SYSTEMD_DIRS}/${JDMC_SERVICE_NAME}"
filesync_service="${JDMC_SYSTEMD_DIRS}/jdmc-ha-filesync-heartbeat.service"
filesync_timer="${JDMC_SYSTEMD_DIRS}/jdmc-ha-filesync-heartbeat.timer"
keepalived_dropin="${JDMC_SYSTEMD_DIRS}/keepalived.service.d/jdmc-ha.conf"
lsyncd_dropin="${JDMC_SYSTEMD_DIRS}/lsyncd.service.d/jdmc-ha.conf"
mkdir -p "${JDMC_SYSTEMD_DIRS}/multi-user.target.wants" \
  "${JDMC_SYSTEMD_DIRS}/keepalived.service.d" "${JDMC_SYSTEMD_DIRS}/lsyncd.service.d"
printf '%s\n' \
  '[Unit]' \
  "Requires=${JDMC_HA_FIREWALL_SERVICE_NAME}" \
  "After=${JDMC_HA_FIREWALL_SERVICE_NAME}" \
  '[Service]' \
  "ExecStartPre=${JDMC_DOCKER_FIREWALL_SCRIPT} prestart" \
  "ExecStartPost=${JDMC_DOCKER_FIREWALL_SCRIPT} apply" >"${ha_dropin}"
printf '%s\n' \
  '[Service]' \
  "ExecStart=${JDMC_DOCKER_FIREWALL_SCRIPT} prestart" >"${ha_service}"
printf '%s\n' \
  '[Service]' \
  "ExecStart=${JDMC_INSTALL_DIR}/current/ha/scripts/filesync.sh heartbeat" >"${filesync_service}"
printf '%s\n' \
  '[Timer]' \
  'OnUnitActiveSec=30s' >"${filesync_timer}"
printf '%s\n' \
  '[Service]' \
  "ExecStopPost=${JDMC_INSTALL_DIR}/current/ha/scripts/role-change.sh STOP" >"${keepalived_dropin}"
printf '%s\n' \
  '[Service]' \
  "ExecStartPre=${JDMC_INSTALL_DIR}/current/ha/scripts/filesync.sh assert-primary" >"${lsyncd_dropin}"
printf '%s\n' \
  '[Service]' \
  "ExecStart=${JDMC_INSTALL_DIR}/jdmc -config ${JDMC_INSTALL_DIR}/jdmc.yaml" >"${main_service}"
ln -s "${ha_service}" "${JDMC_SYSTEMD_DIRS}/multi-user.target.wants/${JDMC_HA_FIREWALL_SERVICE_NAME}"
cleanup_stale_jdmc_docker_hooks
[[ ! -e "${ha_dropin}" ]] || fail 'The stale JDMC Docker drop-in must be removed as a unit'
[[ ! -e "${ha_service}" ]] || fail 'The stale JDMC HA firewall service must be removed'
[[ ! -e "${filesync_service}" && ! -e "${filesync_timer}" ]] ||
  fail 'Stale JDMC HA auxiliary units and timers must be removed'
[[ ! -e "${keepalived_dropin}" && ! -e "${lsyncd_dropin}" ]] ||
  fail 'Stale JDMC HA drop-ins for other services must be removed'
[[ ! -e "${main_service}" ]] || fail 'A JDMC service whose binary is missing must be removed'
[[ ! -L "${JDMC_SYSTEMD_DIRS}/multi-user.target.wants/${JDMC_HA_FIREWALL_SERVICE_NAME}" ]] ||
  fail 'The stale JDMC HA firewall enablement must be removed'
assert_contains "${systemctl_calls[*]}" "disable --now ${JDMC_HA_FIREWALL_SERVICE_NAME}" \
  'The stale JDMC HA firewall service must be stopped and disabled'
printf 'PASS: the complete stale JDMC systemd integration is removed\n'

mkdir -p "$(dirname "${JDMC_DOCKER_FIREWALL_SCRIPT}")"
printf '#!/usr/bin/env bash\n' >"${JDMC_DOCKER_FIREWALL_SCRIPT}"
chmod +x "${JDMC_DOCKER_FIREWALL_SCRIPT}"
printf '%s\n' "ExecStartPre=${JDMC_DOCKER_FIREWALL_SCRIPT}" >>"${docker_unit}"
cleanup_stale_jdmc_docker_hooks
grep -Fq "${JDMC_DOCKER_FIREWALL_SCRIPT}" "${docker_unit}" ||
  fail 'A working JDMC Docker hook must be preserved during installation recovery'
remove_jdmc_docker_hooks
if grep -Fq "${JDMC_DOCKER_FIREWALL_SCRIPT}" "${docker_unit}"; then
  fail 'Uninstall must remove a working JDMC Docker hook'
fi
printf 'PASS: stale JDMC Docker hooks are repaired and uninstall removes active hooks\n'

rm -f "${JDMC_DOCKER_FIREWALL_SCRIPT}"
printf '%s\n' "ExecStartPre=${JDMC_DOCKER_FIREWALL_SCRIPT}" >>"${docker_unit}"
(
  . "${TEST_ROOT}/scripts/2_install_docker.sh"
  prepare_set_redhat_firewalld() { :; }
  docker() { return 0; }
  check_docker_start
)
if grep -Fq "${JDMC_DOCKER_FIREWALL_SCRIPT}" "${docker_unit}"; then
  fail 'Docker checks must repair stale JDMC hooks even while the daemon is running'
fi
printf 'PASS: Docker installation self-heals stale JDMC hooks\n'

calls=()
echo_yellow() { :; }
cleanup_stale_jdmc_docker_hooks() { calls+=(stale); }
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
assert_eq 'stale stop' "${calls[*]}" 'Destructive cleanup must not continue after stop failure'

stop_services() { calls+=(stop); }
calls=()
main
assert_eq 'stale stop jdmc telemetry jumpserver compose docker jmsctl' "${calls[*]}" \
  'The management command must be removed only after cleanup succeeds'
printf 'PASS: uninstall failures propagate and cleanup ordering is safe\n'
