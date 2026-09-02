#!/usr/bin/env bash

# JDMC is a mandatory host-side component in Enterprise Edition. Community
# Edition does not install it. JDMC_SOCK_PATH is kept for Core integration.
JDMC_SERVICE_NAME=${JDMC_SERVICE_NAME:-jdmc.service}
JDMC_CORE_SOCKET_PATH=${JDMC_CORE_SOCKET_PATH:-/opt/jumpserver/data/unshare/jdmc.sock}
JDMC_INSTALL_DIR=${JDMC_INSTALL_DIR:-/opt/jdmc}
JDMC_LEGACY_SERVICE_NAME=${KOTL_SERVICE_NAME:-kotl.service}
JDMC_LEGACY_INSTALL_DIR=${KOTL_INSTALL_DIR:-/opt/kotl}
JDMC_LEGACY_CORE_SOCKET_PATH=${KOTL_CORE_SOCKET_PATH:-/opt/jumpserver/data/unshare/kotl.sock}

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

function get_jdmc_pull_image() {
  local jdmc_image

  jdmc_image=$(get_config_or_env JDMC_IMAGE)
  if [[ -n "${jdmc_image}" ]]; then
    # JDMC_IMAGE is an exact source reference. It must not be rewritten by
    # IMAGE_PULL_PREFIX or the legacy mirror configuration.
    echo "${jdmc_image}"
    return 0
  fi

  # The central image mapping resolves this logical source through
  # IMAGE_PULL_PREFIX and then tags it with the runtime NAMESPACE.
  echo "jumpserver/jdmc:${VERSION}"
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
    configure_jdmc || return 1
    cleanup_jdmc_legacy_switches
    return $?
  fi

  echo_yellow "\n>>> Installing JDMC"
  run_jdmc_package_action install || return 1
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
