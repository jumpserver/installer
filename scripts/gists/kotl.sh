#!/usr/bin/env bash

KOTL_SERVICE_NAME=${KOTL_SERVICE_NAME:-kotl.service}
KOTL_CORE_SOCKET_PATH=${KOTL_CORE_SOCKET_PATH:-/opt/jumpserver/data/unshare/kotl.sock}

function is_enterprise_edition() {
  [[ "$(get_config_or_env USE_XPACK 0)" == "1" ]]
}

function is_kotl_enabled() {
  is_enterprise_edition && [[ "$(get_config_or_env KOTL_ENABLED 1)" == "1" ]]
}

function should_include_kotl_image() {
  is_enterprise_edition || return 1

  case "${INCLUDE_KOTL_IMAGE:-}" in
    1|true|True|TRUE) return 0 ;;
  esac
  is_kotl_enabled
}

function get_kotl_image() {
  echo "${NAMESPACE:-jumpserver}/kotl:${VERSION}"
}

function check_kotl_volume_dir() {
  local volume_dir

  volume_dir=$(get_config_or_env VOLUME_DIR /data/jumpserver)
  volume_dir=${volume_dir%/}
  if [[ "${volume_dir}" != "/data/jumpserver" ]]; then
    log_error "KOTL currently requires VOLUME_DIR=/data/jumpserver (got: ${volume_dir})"
    return 1
  fi
}

function configure_kotl() {
  is_kotl_enabled || return 0
  check_kotl_volume_dir || return 1
  set_config KOTL_ENABLED 1
  set_config JDMC_ENABLED 1
  set_config JDMC_SOCK_PATH "${KOTL_CORE_SOCKET_PATH}"
  gen_safe_config >/dev/null
}

function check_kotl_runtime() {
  if ! command -v systemctl &>/dev/null; then
    log_error "KOTL requires systemd, but systemctl was not found"
    return 1
  fi
}

function check_kotl_installed() {
  [[ -x /opt/kotl/kotl && -f "/etc/systemd/system/${KOTL_SERVICE_NAME}" ]]
}

function run_kotl_package_action() {
  local action=$1
  local image

  image=$(get_kotl_image)
  if ! docker image inspect "${image}" &>/dev/null; then
    log_error "KOTL artifact image not found: ${image}"
    return 1
  fi

  (
    local temp_dir container_id script_path

    if ! temp_dir=$(mktemp -d -t kotl-installer.XXXXXX); then
      log_error "Failed to create a temporary directory for KOTL"
      exit 1
    fi
    container_id=""
    function cleanup_kotl_package() {
      if [[ -n "${container_id}" ]]; then
        docker rm -f "${container_id}" &>/dev/null || true
      fi
      if [[ -n "${temp_dir}" && -d "${temp_dir}" ]]; then
        rm -rf "${temp_dir}"
      fi
    }
    trap cleanup_kotl_package EXIT

    if ! container_id=$(docker create "${image}" /__kotl_artifact_placeholder__); then
      log_error "Failed to create a temporary container from ${image}"
      exit 1
    fi
    if ! docker cp "${container_id}:/dist/." "${temp_dir}/"; then
      log_error "Failed to extract /dist from ${image}"
      exit 1
    fi

    script_path="${temp_dir}/scripts/${action}.sh"
    if [[ ! -f "${script_path}" ]]; then
      log_error "KOTL package script not found: scripts/${action}.sh"
      exit 1
    fi

    chmod +x "${script_path}" || exit 1
    cd "${temp_dir}" || exit 1
    bash "./scripts/${action}.sh"
  )
}

function install_kotl() {
  is_kotl_enabled || return 0
  check_kotl_runtime || return 1
  configure_kotl || return 1

  if check_kotl_installed; then
    echo_check "KOTL is already installed"
    return 0
  fi

  echo_yellow "\n>>> Installing KOTL"
  run_kotl_package_action install
}

function upgrade_kotl() {
  is_kotl_enabled || return 0
  check_kotl_runtime || return 1
  configure_kotl || return 1

  echo_yellow "\n>>> Upgrading KOTL"
  if check_kotl_installed; then
    run_kotl_package_action upgrade
  else
    run_kotl_package_action install
  fi
}

function start_kotl() {
  is_kotl_enabled || return 0
  check_kotl_runtime || return 1
  if ! check_kotl_installed; then
    log_error "KOTL is enabled but not installed; run ./jmsctl.sh install first"
    return 1
  fi
  systemctl start "${KOTL_SERVICE_NAME}"
}

function stop_kotl() {
  is_kotl_enabled || return 0
  check_kotl_runtime || return 1
  check_kotl_installed || return 0
  systemctl stop "${KOTL_SERVICE_NAME}"
}

function restart_kotl() {
  is_kotl_enabled || return 0
  check_kotl_runtime || return 1
  systemctl restart "${KOTL_SERVICE_NAME}"
}

function status_kotl() {
  is_kotl_enabled || return 0
  check_kotl_runtime || return 1
  systemctl status "${KOTL_SERVICE_NAME}" --no-pager || true
}

function tail_kotl() {
  is_kotl_enabled || return 0
  check_kotl_runtime || return 1
  journalctl -u "${KOTL_SERVICE_NAME}" -n 100 -f -o cat
}

function disable_kotl() {
  check_kotl_installed || return 0
  check_kotl_runtime || return 1
  systemctl stop "${KOTL_SERVICE_NAME}" || true
  systemctl disable "${KOTL_SERVICE_NAME}"
}
