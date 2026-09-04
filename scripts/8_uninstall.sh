#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

function stop_services() {
  docker compose version &>/dev/null || return
  if [ -f "${CONFIG_FILE}" ]; then
    cd "${PROJECT_DIR?}" || exit 1
    bash ./jmsctl.sh down
    sleep 2s
    echo
  fi
}

function remove_jmsctl() {
  if check_root && [ -f "/usr/bin/jmsctl" ]; then
    echo -e "$(gettext 'Cleaning up') /usr/bin/jmsctl"
    rm -f /usr/bin/jmsctl
  fi
}

function remove_docker() {
  if check_root && [ -f "/etc/systemd/system/docker.service" ]; then
    echo
    confirm="n"
    read_from_input confirm "$(gettext 'Do you need to clean up the Docker binaries')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      systemctl stop docker
      systemctl disable docker
      systemctl daemon-reload
      local binary
      for binary in docker dockerd docker-init docker-proxy containerd containerd-shim \
        containerd-shim-runc-v2 ctr runc; do
        if [[ -f "/usr/local/bin/${binary}" ]]; then
          echo -e "$(gettext 'Cleaning up') /usr/local/bin/${binary}"
          rm -f "/usr/local/bin/${binary}"
        fi
      done
      echo -e "$(gettext 'Cleaning up') /etc/systemd/system/docker.service"
      rm -f /etc/systemd/system/docker.service
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
      rm -f /usr/local/libexec/docker/cli-plugins/docker-compose
    fi
  fi
  if [ -f "$HOME/.docker/cli-plugins/docker-compose" ]; then
    echo
    confirm="n"
    read_from_input confirm "$(gettext 'Do you need to clean up the Docker Compose binaries')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      echo -e "$(gettext 'Cleaning up') $HOME/.docker/cli-plugins/docker-compose"
      rm -f $HOME/.docker/cli-plugins/docker-compose
    fi
  fi
}

function remove_jumpserver() {
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
      rm -rf "${volume_dir:?}"
    fi
    if [[ -d "${CONFIG_DIR}" ]]; then
      validate_removal_dir "${CONFIG_DIR}" || return 1
      echo -e "$(gettext 'Cleaning up') ${CONFIG_DIR}"
      rm -rf "${CONFIG_DIR:?}"
      rm -f .env compose/.env
    fi
  fi
  echo
  confirm="n"
  read_from_input confirm "$(gettext 'Do you need to clean up the Docker image')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    for image in ${images}; do
      docker rmi "${image}"
      echo
    done
  fi
  echo_green "$(gettext 'Cleanup complete')!"
}

function main() {
  echo_yellow "\n>>> $(gettext 'Uninstall JumpServer')"
  stop_services
  disable_jdmc || log_warn "Failed to disable JDMC"
  installation_log "uninstall"
  remove_jmsctl
  remove_jumpserver
  remove_compose
  remove_docker
}

main
