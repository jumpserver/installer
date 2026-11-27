#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

function stop_services() {
  local container_ids network_ids volume_ids resource_id failed=0

  if [[ -f "${CONFIG_FILE}" ]]; then
    if ! docker compose version &>/dev/null; then
      log_error "Docker Compose is unavailable; cannot safely stop JumpServer services"
      return 1
    fi
    cd "${PROJECT_DIR?}" || return 1
    retire_merged_services stop || return 1
    bash ./jmsctl.sh down || return 1
    sleep 2s
    echo
    return 0
  fi

  command -v docker &>/dev/null || return 0
  container_ids=$(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}") || return 1
  network_ids=$(docker network ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}") || return 1
  volume_ids=$(docker volume ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}") || return 1
  if [[ -n "${container_ids}" ]]; then
    echo_warn "JumpServer configuration is missing; removing containers by the exact Compose project label"
  fi
  for resource_id in ${container_ids}; do
    docker rm -f "${resource_id}" >/dev/null || failed=1
  done
  for resource_id in ${network_ids}; do
    docker network rm "${resource_id}" >/dev/null || failed=1
  done
  for resource_id in ${volume_ids}; do
    docker volume rm "${resource_id}" >/dev/null || failed=1
  done
  if [[ "${failed}" != "0" ]]; then
    log_error "Failed to remove one or more JumpServer Compose resources"
    return 1
  fi
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

function remove_managed_dir() {
  local path=$1

  [[ -e "${path}" || -L "${path}" ]] || return 0
  validate_removal_dir "${path}" || return 1
  echo -e "$(gettext 'Cleaning up') ${path}"
  rm -rf -- "${path:?}"
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
  if [ -f "${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins/docker-compose" ]; then
    echo
    confirm="n"
    read_from_input confirm "$(gettext 'Do you need to clean up the Docker Compose binaries')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      echo -e "$(gettext 'Cleaning up') ${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins/docker-compose"
      rm -f "${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins/docker-compose" || return 1
    fi
  fi
}

function remove_jumpserver() {
  local include_jdmc=${1:-false} images volume_dir image dir
  local failed=0

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo_warn "JumpServer configuration is missing; using the configured environment or default data paths"
  fi
  echo
  echo_warn "$(gettext 'Make sure you have a backup of data, this operation is not reversible')! \n"
  images=$(get_images)
  volume_dir=$(get_config_or_env VOLUME_DIR /data/jumpserver)
  confirm="n"
  read_from_input confirm "$(gettext 'Are you clean up JumpServer files')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    if [[ -f "${CONFIG_FILE}" ]]; then
      retire_merged_services remove || return 1
    fi
    local -a dirs=("${volume_dir}")
    if [[ "${include_jdmc}" == true ]]; then
      dirs+=("$(get_current_jdmc_data_dir)" "$(get_legacy_kotl_data_dir)" "${JDMC_INSTALL_DIR}" "${JDMC_LEGACY_INSTALL_DIR}")
    fi
    for dir in "${dirs[@]}" "${CONFIG_DIR}"; do
      remove_managed_dir "${dir}" || return 1
    done
    rm -f "${PROJECT_DIR}/.env" "${PROJECT_DIR}/compose/.env" || return 1
  fi
  echo
  confirm="n"
  read_from_input confirm "$(gettext 'Do you need to clean up the Docker image')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    if ! command -v docker &>/dev/null; then
      log_error "Docker is unavailable; cannot remove JumpServer images"
      return 1
    fi
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
  check_jdmc_deployment || return 1
  echo_yellow "\n>>> $(gettext 'Uninstall JumpServer')"
  local include_jdmc=false
  if can_manage_existing_jdmc; then
    include_jdmc=true
    prepare_jdmc_uninstall || {
      log_error "Failed to prepare JDMC for uninstall"
      return 1
    }
  fi
  stop_services || return 1
  if [[ "${include_jdmc}" == true ]]; then
    cleanup_jdmc_host_integration || {
      log_error "Failed to clean up JDMC host integration"
      return 1
    }
  fi
  installation_log "uninstall" || true
  remove_jumpserver "${include_jdmc}" || return 1
  remove_compose || return 1
  remove_docker || return 1
  remove_jmsctl
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main "$@"
fi
