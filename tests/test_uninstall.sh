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

VERSION=v5.2.1-ee
USE_XPACK=1
calls=()
echo_yellow() { :; }
prepare_jdmc_uninstall() { calls+=(retire); }
stop_services() { calls+=(stop); return 1; }
cleanup_jdmc_host_integration() { calls+=(jdmc); }
installation_log() { calls+=(telemetry); }
remove_compose() { calls+=(compose); }
remove_docker() { calls+=(docker); }
remove_jmsctl() { calls+=(jmsctl); }

# Run the full uninstall against disposable trees. CE may encounter EE flags or
# data left by another deployment. An EE package can also lose its config file.
for edition in ce ee; do
  (
    VERSION="v5.2.1-${edition}"
    case_dir="${test_dir}/${edition}"
    PROJECT_DIR="${case_dir}/installer"
    CONFIG_DIR="${case_dir}/config"
    CONFIG_FILE="${CONFIG_DIR}/config.txt"
    VOLUME_DIR="${case_dir}/data/jumpserver"
    JDMC_INSTALL_DIR="${case_dir}/opt/jdmc"
    JDMC_LEGACY_INSTALL_DIR="${case_dir}/opt/kotl"
    jdmc_dirs=("$(get_current_jdmc_data_dir)" "$(get_legacy_kotl_data_dir)" "${JDMC_INSTALL_DIR}" "${JDMC_LEGACY_INSTALL_DIR}")
    mkdir -p "${VOLUME_DIR}" "${CONFIG_DIR}" "${PROJECT_DIR}/compose" "${jdmc_dirs[@]}"
    unset USE_XPACK
    if [[ "${edition}" == ce ]]; then
      echo USE_XPACK=1 >"${CONFIG_FILE}"
    fi
    # Confirm only the file cleanup, never Docker image removal.
    count=0
    read_from_input() {
      count=$((count + 1))
      if [[ "${count}" == 1 ]]; then printf -v "$1" y; else printf -v "$1" n; fi
    }
    get_images() { :; }
    stop_services() { calls+=(stop); }
    main
    [[ ! -e "${VOLUME_DIR}" && ! -e "${CONFIG_DIR}" ]] || fail 'JumpServer files should be removed'
    if [[ "${edition}" == ce ]]; then
      assert_eq 'stop telemetry compose docker jmsctl' "${calls[*]}" 'CE must leave JDMC integration alone'
      for dir in "${jdmc_dirs[@]}"; do [[ -d "${dir}" ]] || fail "CE removed ${dir}"; done
    else
      assert_eq 'retire stop jdmc telemetry compose docker jmsctl' "${calls[*]}" 'EE must retire JDMC with missing config'
      for dir in "${jdmc_dirs[@]}"; do [[ ! -e "${dir}" ]] || fail "EE left ${dir}"; done
    fi
  )
done
printf 'PASS: CE preserves JDMC/KOTL volumes and services, EE can clean up without config\n'

remove_jumpserver() { calls+=(jumpserver); }
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
