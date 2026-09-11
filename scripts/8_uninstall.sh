#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

function stop_services() {
  [[ -f "${CONFIG_FILE}" ]] || return 0
  if ! docker compose version &>/dev/null; then
    log_error "Docker Compose is unavailable; cannot safely stop JumpServer services"
    return 1
  fi
  cd "${PROJECT_DIR?}" || return 1
  bash ./jmsctl.sh down || return 1
  sleep 2s
  echo
}

function remove_jmsctl() {
  if check_root && [ -f "/usr/bin/jmsctl" ]; then
    echo -e "$(gettext 'Cleaning up') /usr/bin/jmsctl"
    rm -f /usr/bin/jmsctl || return 1
  fi
}

function remove_docker() {
  if check_root && [ -f "/etc/systemd/system/docker.service" ]; then
    echo
    confirm="n"
    read_from_input confirm "$(gettext 'Do you need to clean up the Docker binaries')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      systemctl stop docker || return 1
      systemctl disable docker || return 1
      local binary
      for binary in docker dockerd docker-init docker-proxy containerd containerd-shim \
        containerd-shim-runc-v2 ctr runc; do
        if [[ -f "/usr/local/bin/${binary}" ]]; then
          echo -e "$(gettext 'Cleaning up') /usr/local/bin/${binary}"
          rm -f "/usr/local/bin/${binary}" || return 1
        fi
      done
      echo -e "$(gettext 'Cleaning up') /etc/systemd/system/docker.service"
      rm -f /etc/systemd/system/docker.service || return 1
      systemctl daemon-reload || return 1
    fi
  fi
}

function validate_removal_dir() {
  local path=${1%/}
  if [[ -d "${path}" ]]; then
    path=$(cd "${path}" 2>/dev/null && pwd -P) || return 1
  fi
  case "${path}" in
    ""|/|/bin|/boot|/data|/dev|/etc|/home|/mnt|/opt|/root|/run|/srv|/tmp|/usr|/var)
      log_error "Refusing to recursively remove unsafe directory: ${path:-<empty>}"
      return 1
      ;;
  esac
  [[ "${path}" == /* ]] || {
    log_error "Refusing to recursively remove a non-absolute directory: ${path}"
    return 1
  }
}

function remove_compose() {
  if check_root && [ -f "/usr/local/libexec/docker/cli-plugins/docker-compose" ]; then
    echo
    confirm="n"
    read_from_input confirm "$(gettext 'Do you need to clean up the Docker Compose binaries')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      echo -e "$(gettext 'Cleaning up') /usr/local/libexec/docker/cli-plugins/docker-compose"
      rm -f /usr/local/libexec/docker/cli-plugins/docker-compose || return 1
    fi
  fi
  if [ -f "$HOME/.docker/cli-plugins/docker-compose" ]; then
    echo
    confirm="n"
    read_from_input confirm "$(gettext 'Do you need to clean up the Docker Compose binaries')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      echo -e "$(gettext 'Cleaning up') $HOME/.docker/cli-plugins/docker-compose"
      rm -f "$HOME/.docker/cli-plugins/docker-compose" || return 1
    fi
  fi
}

function remove_jumpserver() {
  local images volume_dir image
  local failed=0

  if [ ! -f "${CONFIG_FILE}" ]; then
    return
  fi
  echo
  echo_warn "$(gettext 'Make sure you have a backup of data, this operation is not reversible')! \n"
  images=$(get_images)
  volume_dir=$(get_config VOLUME_DIR)
  confirm="n"
  read_from_input confirm "$(gettext 'Are you clean up JumpServer files')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    if [[ -d "${volume_dir}" ]]; then
      validate_removal_dir "${volume_dir}" || return 1
      echo -e "$(gettext 'Cleaning up') ${volume_dir}"
      rm -rf "${volume_dir:?}" || return 1
    fi
    if [[ -d "${CONFIG_DIR}" ]]; then
      validate_removal_dir "${CONFIG_DIR}" || return 1
      echo -e "$(gettext 'Cleaning up') ${CONFIG_DIR}"
      rm -rf "${CONFIG_DIR:?}" || return 1
    fi
    rm -f "${PROJECT_DIR}/.env" "${PROJECT_DIR}/compose/.env" || return 1
  fi
  echo
  confirm="n"
  read_from_input confirm "$(gettext 'Do you need to clean up the Docker image')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    for image in ${images}; do
      docker rmi "${image}" || failed=1
      echo
    done
  fi
  if [[ "${failed}" != "0" ]]; then
    log_error "Failed to remove one or more JumpServer images"
    return 1
  fi
  echo_green "$(gettext 'Cleanup complete')!"
}

function main() {
  echo_yellow "\n>>> $(gettext 'Uninstall JumpServer')"
  cleanup_stale_jdmc_docker_hooks || {
    log_error "Failed to remove stale JDMC Docker hooks"
    return 1
  }
  stop_services || return 1
  cleanup_jdmc_host_integration || {
    log_error "Failed to clean up JDMC host integration"
    return 1
  }
  installation_log "uninstall" || true
  remove_jumpserver || return 1
  remove_compose || return 1
  remove_docker || return 1
  remove_jmsctl
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main "$@"
fi
