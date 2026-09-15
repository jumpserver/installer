#!/usr/bin/env bash

# JDMC is a mandatory host-side component in Enterprise Edition. Community
# Edition does not install it. JDMC_SOCK_PATH is kept for Core integration.
JDMC_SERVICE_NAME=${JDMC_SERVICE_NAME:-jdmc.service}
JDMC_CORE_SOCKET_PATH=${JDMC_CORE_SOCKET_PATH:-/opt/jumpserver/data/unshare/jdmc.sock}
JDMC_INSTALL_DIR=${JDMC_INSTALL_DIR:-/opt/jdmc}
JDMC_LEGACY_SERVICE_NAME=${KOTL_SERVICE_NAME:-kotl.service}
JDMC_LEGACY_INSTALL_DIR=${KOTL_INSTALL_DIR:-/opt/kotl}
JDMC_LEGACY_CORE_SOCKET_PATH=${KOTL_CORE_SOCKET_PATH:-/opt/jumpserver/data/unshare/kotl.sock}
JDMC_DOCKER_FIREWALL_SCRIPT=${JDMC_DOCKER_FIREWALL_SCRIPT:-${JDMC_INSTALL_DIR}/current/ha/scripts/firewall.sh}
JDMC_LEGACY_DOCKER_FIREWALL_SCRIPT=${JDMC_LEGACY_DOCKER_FIREWALL_SCRIPT:-${JDMC_LEGACY_INSTALL_DIR}/current/ha/scripts/firewall.sh}
JDMC_HA_CLI=${JDMC_HA_CLI:-${JDMC_INSTALL_DIR}/current/ha/ha.sh}
JDMC_HA_FIREWALL_SERVICE_NAME=${JDMC_HA_FIREWALL_SERVICE_NAME:-jdmc-ha-firewall.service}
JDMC_DOCKER_HA_DROPIN_NAME=${JDMC_DOCKER_HA_DROPIN_NAME:-jdmc-ha-firewall.conf}
JDMC_HA_SYSTEMD_UNITS=${JDMC_HA_SYSTEMD_UNITS:-jdmc-ha-firewall.service jdmc-ha-filesync-heartbeat.service jdmc-ha-filesync-heartbeat.timer jdmc-ha-rejoin.service jdmc-ha-rejoin.timer jdmc-ha-source-recovery.service jdmc-ha-source-recovery.timer}
JDMC_HA_SYSTEMD_DROPINS=${JDMC_HA_SYSTEMD_DROPINS:-docker.service.d/${JDMC_DOCKER_HA_DROPIN_NAME} keepalived.service.d/jdmc-ha.conf lsyncd.service.d/jdmc-ha.conf}
JDMC_SYSTEMD_DIRS=${JDMC_SYSTEMD_DIRS:-/etc/systemd/system:/run/systemd/system:/usr/local/lib/systemd/system:/usr/lib/systemd/system:/lib/systemd/system}

function is_enterprise_edition() {
  [[ "$(get_config_or_env USE_XPACK 0)" == "1" ]]
}

function is_jdmc_enabled() {
  is_enterprise_edition
}

function should_include_jdmc_image() {
  is_jdmc_enabled
}

function get_jdmc_image() {
  local namespace

  namespace=$(get_config_or_env NAMESPACE jumpserver)
  namespace=${namespace%/}
  echo "${namespace:-jumpserver}/jdmc:${VERSION}"
}

function configure_jdmc() {
  local socket_path

  # JDMC follows the edition and is no longer configurable. Legacy switches
  # are deliberately ignored here and cleaned only after install/upgrade has
  # succeeded, so a failed upgrade can still be rolled back with its old config.
  if ! is_enterprise_edition; then
    gen_safe_config >/dev/null
    return 0
  fi

  socket_path="${JDMC_CORE_SOCKET_PATH}"
  if check_legacy_kotl_installed && ! check_current_jdmc_installed; then
    # Keep Core connected to a still-running legacy service until the new
    # artifact has completed its on-host migration.
    socket_path=$(get_config_or_env JDMC_SOCK_PATH "${JDMC_LEGACY_CORE_SOCKET_PATH}")
  fi
  set_config JDMC_SOCK_PATH "${socket_path}"
  gen_safe_config >/dev/null
}

function cleanup_jdmc_legacy_switches() {
  remove_config KOTL_ENABLED
  remove_config JDMC_HOST_ENABLED
  remove_config JDMC_ENABLED
  gen_safe_config >/dev/null
}

function check_jdmc_runtime() {
  if ! command -v systemctl &>/dev/null; then
    log_error "JDMC requires systemd, but systemctl was not found"
    return 1
  fi
}

function ensure_jdmc_ha_dependencies() {
  local dependency_installer="${JDMC_INSTALL_DIR}/current/ha/scripts/install-dependencies.sh"

  if [[ ! -x "${dependency_installer}" ]]; then
    log_error "JDMC HA dependency installer not found: ${dependency_installer}"
    return 1
  fi
  echo_yellow "\n>>> Installing JDMC HA host dependencies"
  "${dependency_installer}"
}

function jdmc_unit_exists() {
  local service_name=$1

  [[ -f "/etc/systemd/system/${service_name}" ||
    -f "/lib/systemd/system/${service_name}" ||
    -f "/usr/lib/systemd/system/${service_name}" ]]
}

function jdmc_path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

function get_jdmc_storage_root() {
  local volume_dir

  volume_dir=$(get_config_or_env VOLUME_DIR /data/jumpserver)
  volume_dir="${volume_dir%/}"
  [[ -n "${volume_dir}" ]] || volume_dir=/data/jumpserver
  dirname "${volume_dir}"
}

function get_current_jdmc_data_dir() {
  echo "$(get_jdmc_storage_root)/jdmc"
}

function get_legacy_kotl_data_dir() {
  echo "$(get_jdmc_storage_root)/kotl"
}

function jdmc_ha_lifecycle_present() {
  local state_dir=$1 marker

  for marker in installed rollback-terminal.json standalone-prepare standalone retired-safe; do
    if jdmc_path_exists "${state_dir}/${marker}"; then
      return 0
    fi
  done
  return 1
}

function retire_jdmc_ha_lifecycle() {
  local data_dir=$1 ha_cli=$2
  local volume_dir

  jdmc_ha_lifecycle_present "${data_dir}/ha" || return 0
  if [[ ! -x "${ha_cli}" ]]; then
    log_error "JDMC HA state exists, but the safe HA uninstall command is missing: ${ha_cli}"
    log_error "Repair JDMC before uninstalling; refusing to remove an active or ambiguous HA node"
    return 1
  fi
  volume_dir=$(get_config_or_env VOLUME_DIR /data/jumpserver)
  echo_yellow "\n>>> Safely retiring JDMC HA"
  JUMPSERVER_VOLUME_DIR="${volume_dir}" "${ha_cli}" uninstall
}

function prepare_jdmc_uninstall() {
  retire_jdmc_ha_lifecycle "$(get_current_jdmc_data_dir)" "${JDMC_HA_CLI}"
}

function check_current_jdmc_installed() {
  [[ -x "${JDMC_INSTALL_DIR}/jdmc" ]] && jdmc_unit_exists "${JDMC_SERVICE_NAME}"
}

function check_legacy_kotl_installed() {
  [[ -x "${JDMC_LEGACY_INSTALL_DIR}/kotl" ]] && jdmc_unit_exists "${JDMC_LEGACY_SERVICE_NAME}"
}

function check_current_jdmc_footprint() {
  local data_dir

  data_dir=$(get_current_jdmc_data_dir)
  jdmc_unit_exists "${JDMC_SERVICE_NAME}" ||
    jdmc_path_exists "${JDMC_INSTALL_DIR}" ||
    jdmc_path_exists "${data_dir}"
}

function check_legacy_kotl_footprint() {
  local data_dir

  data_dir=$(get_legacy_kotl_data_dir)
  jdmc_unit_exists "${JDMC_LEGACY_SERVICE_NAME}" ||
    jdmc_path_exists "${JDMC_LEGACY_INSTALL_DIR}" ||
    jdmc_path_exists "${data_dir}"
}

function check_jdmc_installed() {
  # Upgrade scripts can repair partial installs and migrate data-only legacy
  # layouts, so any recognizable footprint must take the upgrade path.
  check_current_jdmc_footprint || check_legacy_kotl_footprint
}

function check_jdmc_service_installed() {
  jdmc_unit_exists "${JDMC_SERVICE_NAME}" || jdmc_unit_exists "${JDMC_LEGACY_SERVICE_NAME}"
}

function get_installed_jdmc_service_name() {
  if jdmc_unit_exists "${JDMC_SERVICE_NAME}"; then
    echo "${JDMC_SERVICE_NAME}"
  elif jdmc_unit_exists "${JDMC_LEGACY_SERVICE_NAME}"; then
    echo "${JDMC_LEGACY_SERVICE_NAME}"
  else
    echo "${JDMC_SERVICE_NAME}"
  fi
}

function run_jdmc_package_action() {
  local action=$1
  local image volume_dir

  image=$(get_jdmc_image)
  volume_dir=$(get_config_or_env VOLUME_DIR /data/jumpserver)
  if ! docker image inspect "${image}" &>/dev/null; then
    log_error "JDMC artifact image not found: ${image}"
    return 1
  fi

  (
    local temp_dir container_id script_path

    if ! temp_dir=$(mktemp -d -t jdmc-installer.XXXXXX); then
      log_error "Failed to create a temporary directory for JDMC"
      exit 1
    fi
    container_id=""
    function cleanup_jdmc_package() {
      if [[ -n "${container_id}" ]]; then
        docker rm -f "${container_id}" &>/dev/null || true
      fi
      if [[ -n "${temp_dir}" && -d "${temp_dir}" ]]; then
        rm -rf "${temp_dir}"
      fi
    }
    trap cleanup_jdmc_package EXIT

    if ! container_id=$(docker create "${image}" /__jdmc_artifact_placeholder__); then
      log_error "Failed to create a temporary container from ${image}"
      exit 1
    fi
    if ! docker cp "${container_id}:/dist/." "${temp_dir}/"; then
      log_error "Failed to extract /dist from ${image}"
      exit 1
    fi

    script_path="${temp_dir}/scripts/${action}.sh"
    if [[ ! -f "${script_path}" ]]; then
      log_error "JDMC package script not found: scripts/${action}.sh"
      exit 1
    fi

    chmod +x "${script_path}" || exit 1
    cd "${temp_dir}" || exit 1
    # JDMC runs on the host, so its package scripts need the host-side
    # JumpServer data root instead of paths mounted inside Compose.
    JUMPSERVER_VOLUME_DIR="${volume_dir}"
    export JUMPSERVER_VOLUME_DIR
    bash "./scripts/${action}.sh"
  )
}

function install_jdmc() {
  if ! is_jdmc_enabled; then
    cleanup_jdmc_legacy_switches
    return $?
  fi
  check_jdmc_runtime || return 1
  configure_jdmc || return 1

  if check_current_jdmc_installed; then
    echo_check "JDMC is already installed"
    ensure_jdmc_ha_dependencies || return 1
    cleanup_jdmc_legacy_switches
    return $?
  fi

  if check_jdmc_installed; then
    if check_legacy_kotl_footprint && ! check_current_jdmc_footprint; then
      echo_yellow "\n>>> Migrating KOTL to JDMC"
    else
      echo_yellow "\n>>> Repairing or upgrading JDMC"
    fi
    run_jdmc_package_action upgrade || return 1
    ensure_jdmc_ha_dependencies || return 1
    configure_jdmc || return 1
    cleanup_jdmc_legacy_switches
    return $?
  fi

  echo_yellow "\n>>> Installing JDMC"
  run_jdmc_package_action install || return 1
  ensure_jdmc_ha_dependencies || return 1
  configure_jdmc || return 1
  cleanup_jdmc_legacy_switches
}

function upgrade_jdmc() {
  if ! is_jdmc_enabled; then
    cleanup_jdmc_legacy_switches
    return $?
  fi
  check_jdmc_runtime || return 1
  configure_jdmc || return 1

  echo_yellow "\n>>> Upgrading JDMC"
  if check_jdmc_installed; then
    run_jdmc_package_action upgrade || return 1
  else
    run_jdmc_package_action install || return 1
  fi
  ensure_jdmc_ha_dependencies || return 1
  configure_jdmc || return 1
  cleanup_jdmc_legacy_switches
}

function start_jdmc() {
  local service_name

  is_jdmc_enabled || return 0
  check_jdmc_runtime || return 1
  if ! check_jdmc_service_installed; then
    log_error "JDMC service is not installed; run ./jmsctl.sh install first"
    return 1
  fi
  service_name=$(get_installed_jdmc_service_name)
  systemctl start "${service_name}"
}

function stop_jdmc() {
  local failed=0

  check_jdmc_service_installed || return 0
  check_jdmc_runtime || return 1
  if jdmc_unit_exists "${JDMC_SERVICE_NAME}"; then
    systemctl stop "${JDMC_SERVICE_NAME}" || failed=1
  fi
  if [[ "${JDMC_LEGACY_SERVICE_NAME}" != "${JDMC_SERVICE_NAME}" ]] && \
    jdmc_unit_exists "${JDMC_LEGACY_SERVICE_NAME}"; then
    systemctl stop "${JDMC_LEGACY_SERVICE_NAME}" || failed=1
  fi
  return "${failed}"
}

function restart_jdmc() {
  local service_name

  if ! is_jdmc_enabled; then
    stop_jdmc
    return $?
  fi
  check_jdmc_runtime || return 1
  if ! check_jdmc_service_installed; then
    log_error "JDMC is enabled but not installed; run ./jmsctl.sh install first"
    return 1
  fi
  service_name=$(get_installed_jdmc_service_name)
  systemctl restart "${service_name}"
}

function status_jdmc() {
  local service_name

  check_jdmc_service_installed || return 0
  check_jdmc_runtime || return 1
  service_name=$(get_installed_jdmc_service_name)
  systemctl status "${service_name}" --no-pager || true
}

function tail_jdmc() {
  local service_name

  check_jdmc_runtime || return 1
  if ! check_jdmc_service_installed; then
    log_error "JDMC service is not installed; run ./jmsctl.sh install first"
    return 1
  fi
  service_name=$(get_installed_jdmc_service_name)
  journalctl -u "${service_name}" -n 100 -f -o cat
}

function disable_jdmc_service() {
  local service_name=$1
  local failed=0

  jdmc_unit_exists "${service_name}" || return 0
  systemctl stop "${service_name}" || failed=1
  systemctl disable "${service_name}" || failed=1
  return "${failed}"
}

function disable_jdmc() {
  local failed=0

  check_jdmc_runtime || return 1
  disable_jdmc_service "${JDMC_SERVICE_NAME}" || failed=1
  if [[ "${JDMC_LEGACY_SERVICE_NAME}" != "${JDMC_SERVICE_NAME}" ]]; then
    disable_jdmc_service "${JDMC_LEGACY_SERVICE_NAME}" || failed=1
  fi
  return "${failed}"
}

function remove_jdmc_docker_hook_from_file() {
  local unit_file=$1 hook_path=$2
  local line tmp_file
  local changed=0

  grep -Fq "${hook_path}" "${unit_file}" 2>/dev/null || return 0
  tmp_file=$(mktemp -t jdmc-docker-unit.XXXXXX) || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^[[:space:]]*ExecStart(Pre|Post)= ]] && [[ "${line}" == *"${hook_path}"* ]]; then
      changed=1
      continue
    fi
    printf '%s\n' "${line}"
  done <"${unit_file}" >"${tmp_file}"

  if [[ "${changed}" == "1" ]]; then
    echo -e "$(gettext 'Cleaning up') JDMC Docker hook: ${unit_file}"
    if ! cat "${tmp_file}" >"${unit_file}"; then
      rm -f "${tmp_file}"
      return 1
    fi
    JDMC_DOCKER_HOOK_CHANGED=1
  fi
  rm -f "${tmp_file}"
}

function remove_jdmc_docker_dependency_from_file() {
  local unit_file=$1
  local line tmp_file dependency remaining_dependencies
  local changed=0 removed=0
  local -a dependencies

  grep -Fq "${JDMC_HA_FIREWALL_SERVICE_NAME}" "${unit_file}" 2>/dev/null || return 0
  tmp_file=$(mktemp -t jdmc-docker-unit.XXXXXX) || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^[[:space:]]*(Requires|Wants|After|Before)= ]] && \
      [[ "${line}" == *"${JDMC_HA_FIREWALL_SERVICE_NAME}"* ]]; then
      removed=0
      remaining_dependencies=""
      IFS=$' \t' read -r -a dependencies <<<"${line#*=}"
      for dependency in "${dependencies[@]}"; do
        if [[ "${dependency}" == "${JDMC_HA_FIREWALL_SERVICE_NAME}" ]]; then
          removed=1
          continue
        fi
        remaining_dependencies="${remaining_dependencies}${remaining_dependencies:+ }${dependency}"
      done
      if [[ "${removed}" == "1" ]]; then
        changed=1
        if [[ -n "${remaining_dependencies}" ]]; then
          printf '%s=%s\n' "${line%%=*}" "${remaining_dependencies}"
        fi
        continue
      fi
    fi
    printf '%s\n' "${line}"
  done <"${unit_file}" >"${tmp_file}"

  if [[ "${changed}" == "1" ]]; then
    echo -e "$(gettext 'Cleaning up') JDMC Docker dependency: ${unit_file}"
    if ! cat "${tmp_file}" >"${unit_file}"; then
      rm -f "${tmp_file}"
      return 1
    fi
    JDMC_DOCKER_HOOK_CHANGED=1
  fi
  rm -f "${tmp_file}"
}

function remove_jdmc_firewall_hook() {
  local command_name=$1 parent=$2 child=$3

  while "${command_name}" -C "${parent}" -j "${child}" &>/dev/null; do
    "${command_name}" -D "${parent}" -j "${child}" &>/dev/null || return 1
  done
  ! "${command_name}" -C "${parent}" -j "${child}" &>/dev/null
}

function remove_jdmc_firewall_chain() {
  local command_name=$1 chain=$2

  if "${command_name}" -nL "${chain}" &>/dev/null; then
    "${command_name}" -F "${chain}" &>/dev/null || return 1
    "${command_name}" -X "${chain}" &>/dev/null || return 1
  fi
  ! "${command_name}" -nL "${chain}" &>/dev/null
}

function remove_jdmc_firewall_family() {
  local command_name=$1 suffix chain

  if ! command -v "${command_name}" &>/dev/null; then
    echo_warn "Cannot verify stale JDMC HA firewall rules because ${command_name} is unavailable"
    return 0
  fi
  remove_jdmc_firewall_hook "${command_name}" INPUT JDMC_HA_INPUT || return 1
  remove_jdmc_firewall_hook "${command_name}" DOCKER-USER JDMC_HA_DOCKER || return 1
  remove_jdmc_firewall_hook "${command_name}" FORWARD JDMC_HA_DOCKER || return 1
  for suffix in A B C; do
    remove_jdmc_firewall_hook "${command_name}" INPUT "JDMC_HA_GUARD_IN_${suffix}" || return 1
    remove_jdmc_firewall_hook "${command_name}" DOCKER-USER "JDMC_HA_GUARD_FWD_${suffix}" || return 1
    remove_jdmc_firewall_hook "${command_name}" FORWARD "JDMC_HA_GUARD_FWD_${suffix}" || return 1
  done
  for chain in JDMC_HA_INPUT JDMC_HA_DOCKER \
    JDMC_HA_GUARD_IN_A JDMC_HA_GUARD_IN_B JDMC_HA_GUARD_IN_C \
    JDMC_HA_GUARD_FWD_A JDMC_HA_GUARD_FWD_B JDMC_HA_GUARD_FWD_C; do
    remove_jdmc_firewall_chain "${command_name}" "${chain}" || return 1
  done
}

function remove_jdmc_firewall_rules() {
  local failed=0

  remove_jdmc_firewall_family iptables || failed=1
  remove_jdmc_firewall_family ip6tables || failed=1
  if [[ "${failed}" != "0" ]]; then
    log_error "Failed to remove all JDMC HA firewall hooks and chains"
    return 1
  fi
}

function remove_jdmc_docker_hooks() {
  local systemd_dir unit_file hook_path hook_root unit_name relative_path target_name candidate unit_present
  local failed=0
  local remove_ha_service=0
  local remove_firewall_rules=0
  local ha_service_present=0
  local keepalived_dropin_present=0
  local lsyncd_dropin_present=0
  local JDMC_DOCKER_HOOK_CHANGED=0
  local -a systemd_dirs hook_paths hook_roots

  IFS=: read -r -a systemd_dirs <<<"${JDMC_SYSTEMD_DIRS}"
  if [[ "$#" -gt 0 ]]; then
    hook_paths=("$@")
  else
    hook_paths=("${JDMC_DOCKER_FIREWALL_SCRIPT}" "${JDMC_LEGACY_DOCKER_FIREWALL_SCRIPT}")
    remove_ha_service=1
  fi
  for hook_path in "${hook_paths[@]}"; do
    hook_roots+=("${hook_path%/ha/scripts/firewall.sh}")
  done

  for systemd_dir in "${systemd_dirs[@]}"; do
    for unit_name in ${JDMC_HA_SYSTEMD_UNITS}; do
      candidate="${systemd_dir}/${unit_name}"
      if [[ -f "${candidate}" ]]; then
        ha_service_present=1
      fi
      [[ -f "${candidate}" ]] || continue
      for hook_root in "${hook_roots[@]}"; do
        if grep -Fq "${hook_root}/" "${candidate}" 2>/dev/null; then
          remove_ha_service=1
        fi
      done
    done
    for relative_path in ${JDMC_HA_SYSTEMD_DROPINS}; do
      candidate="${systemd_dir}/${relative_path}"
      [[ -f "${candidate}" ]] || continue
      ha_service_present=1
      [[ "${relative_path}" == "keepalived.service.d/jdmc-ha.conf" ]] && keepalived_dropin_present=1
      [[ "${relative_path}" == "lsyncd.service.d/jdmc-ha.conf" ]] && lsyncd_dropin_present=1
      for hook_root in "${hook_roots[@]}"; do
        if grep -Fq "${hook_root}/" "${candidate}" 2>/dev/null; then
          remove_ha_service=1
        fi
      done
    done
    for unit_file in "${systemd_dir}/docker.service" "${systemd_dir}/docker.service.d/"*.conf; do
      [[ -f "${unit_file}" ]] || continue
      for hook_path in "${hook_paths[@]}"; do
        if grep -Fq "${hook_path}" "${unit_file}" 2>/dev/null; then
          remove_firewall_rules=1
        fi
      done
    done
  done

  if [[ "${remove_ha_service}" == "1" && "${ha_service_present}" == "1" ]] && command -v systemctl &>/dev/null; then
    for unit_name in ${JDMC_HA_SYSTEMD_UNITS}; do
      unit_present=0
      for systemd_dir in "${systemd_dirs[@]}"; do
        [[ -f "${systemd_dir}/${unit_name}" ]] && unit_present=1
      done
      if [[ "${unit_present}" == "1" ]]; then
        systemctl disable --now "${unit_name}" &>/dev/null || systemctl stop "${unit_name}" &>/dev/null || failed=1
      fi
    done
    if [[ "${keepalived_dropin_present}" == "1" ]]; then
      systemctl stop keepalived.service &>/dev/null || failed=1
    fi
    if [[ "${lsyncd_dropin_present}" == "1" ]]; then
      systemctl stop lsyncd.service &>/dev/null || failed=1
    fi
  fi

  if [[ "${failed}" != "0" ]]; then
    log_error "Failed to stop stale JDMC HA services; preserving their files for recovery"
    return 1
  fi
  if [[ "${remove_ha_service}" == "1" || "${remove_firewall_rules}" == "1" ]]; then
    remove_jdmc_firewall_rules || return 1
  fi

  for systemd_dir in "${systemd_dirs[@]}"; do
    if [[ "${remove_ha_service}" == "1" ]]; then
      for relative_path in ${JDMC_HA_SYSTEMD_DROPINS} ${JDMC_HA_SYSTEMD_UNITS}; do
        candidate="${systemd_dir}/${relative_path}"
        if [[ -e "${candidate}" || -L "${candidate}" ]]; then
          echo -e "$(gettext 'Cleaning up') ${candidate}"
          if rm -f "${candidate}"; then
            JDMC_DOCKER_HOOK_CHANGED=1
          else
            failed=1
          fi
        fi
      done
      for target_name in multi-user.target.wants timers.target.wants; do
        for unit_name in ${JDMC_HA_SYSTEMD_UNITS}; do
          candidate="${systemd_dir}/${target_name}/${unit_name}"
          if [[ -e "${candidate}" || -L "${candidate}" ]]; then
            echo -e "$(gettext 'Cleaning up') ${candidate}"
            if rm -f "${candidate}"; then
              JDMC_DOCKER_HOOK_CHANGED=1
            else
              failed=1
            fi
          fi
        done
      done
    fi
    for unit_file in "${systemd_dir}/docker.service" "${systemd_dir}/docker.service.d/"*.conf; do
      [[ -f "${unit_file}" ]] || continue
      for hook_path in "${hook_paths[@]}"; do
        remove_jdmc_docker_hook_from_file "${unit_file}" "${hook_path}" || failed=1
      done
      if [[ "${remove_ha_service}" == "1" ]]; then
        remove_jdmc_docker_dependency_from_file "${unit_file}" || failed=1
      fi
    done
  done

  if [[ "${JDMC_DOCKER_HOOK_CHANGED}" == "1" ]] && command -v systemctl &>/dev/null; then
    systemctl daemon-reload || failed=1
    systemctl reset-failed docker &>/dev/null || true
  fi
  return "${failed}"
}

function remove_jdmc_main_service_unit() {
  local service_name=$1 install_dir=$2
  local systemd_dir candidate target_name
  local failed=0
  local changed=0
  local present=0
  local unit_file_present=0
  local -a systemd_dirs

  IFS=: read -r -a systemd_dirs <<<"${JDMC_SYSTEMD_DIRS}"
  for systemd_dir in "${systemd_dirs[@]}"; do
    if [[ -f "${systemd_dir}/${service_name}" ||
      -e "${systemd_dir}/multi-user.target.wants/${service_name}" ||
      -L "${systemd_dir}/multi-user.target.wants/${service_name}" ]]; then
      present=1
    fi
    [[ -f "${systemd_dir}/${service_name}" ]] && unit_file_present=1
  done
  [[ "${present}" == "1" ]] || return 0

  if [[ "${unit_file_present}" == "1" ]] && command -v systemctl &>/dev/null; then
    systemctl disable --now "${service_name}" &>/dev/null || systemctl stop "${service_name}" &>/dev/null || failed=1
  fi
  for systemd_dir in "${systemd_dirs[@]}"; do
    for target_name in "" multi-user.target.wants; do
      if [[ -n "${target_name}" ]]; then
        candidate="${systemd_dir}/${target_name}/${service_name}"
      else
        candidate="${systemd_dir}/${service_name}"
      fi
      if [[ -e "${candidate}" || -L "${candidate}" ]]; then
        if [[ -f "${candidate}" ]] && ! grep -Fq "${install_dir}" "${candidate}" 2>/dev/null; then
          continue
        fi
        echo -e "$(gettext 'Cleaning up') ${candidate}"
        if rm -f "${candidate}"; then
          changed=1
        else
          failed=1
        fi
      fi
    done
  done
  if [[ "${changed}" == "1" ]] && command -v systemctl &>/dev/null; then
    systemctl daemon-reload || failed=1
  fi
  return "${failed}"
}

function cleanup_stale_jdmc_docker_hooks() {
  local failed=0
  local -a stale_hooks=()

  [[ -x "${JDMC_DOCKER_FIREWALL_SCRIPT}" ]] || stale_hooks+=("${JDMC_DOCKER_FIREWALL_SCRIPT}")
  [[ -x "${JDMC_LEGACY_DOCKER_FIREWALL_SCRIPT}" ]] || stale_hooks+=("${JDMC_LEGACY_DOCKER_FIREWALL_SCRIPT}")
  if [[ "${#stale_hooks[@]}" -gt 0 ]]; then
    remove_jdmc_docker_hooks "${stale_hooks[@]}" || failed=1
  fi
  if [[ ! -x "${JDMC_INSTALL_DIR}/jdmc" ]]; then
    remove_jdmc_main_service_unit "${JDMC_SERVICE_NAME}" "${JDMC_INSTALL_DIR}" || failed=1
  fi
  if [[ ! -x "${JDMC_LEGACY_INSTALL_DIR}/kotl" ]]; then
    remove_jdmc_main_service_unit "${JDMC_LEGACY_SERVICE_NAME}" "${JDMC_LEGACY_INSTALL_DIR}" || failed=1
  fi
  return "${failed}"
}

function cleanup_jdmc_host_integration() {
  local failed=0

  if check_jdmc_service_installed; then
    disable_jdmc || failed=1
  fi
  remove_jdmc_docker_hooks || failed=1
  remove_jdmc_main_service_unit "${JDMC_SERVICE_NAME}" "${JDMC_INSTALL_DIR}" || failed=1
  remove_jdmc_main_service_unit "${JDMC_LEGACY_SERVICE_NAME}" "${JDMC_LEGACY_INSTALL_DIR}" || failed=1
  return "${failed}"
}
