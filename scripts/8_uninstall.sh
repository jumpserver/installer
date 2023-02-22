#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

function remove_jumpserver() {
  echo_warn "$(gettext 'Make sure you have a backup of data, this operation is not reversible')! \n"
  images=$(get_images)
  volume_dir=$(get_config VOLUME_DIR)
  confirm="n"
  read_from_input confirm "$(gettext 'Are you clean up JumpServer files')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    if [[ -f "${CONFIG_FILE}" ]]; then
      cd "${PROJECT_DIR}" || exit 1
      bash ./jmsctl.sh down
      sleep 2s
      echo
      echo -e "$(gettext 'Cleaning up') ${volume_dir}"
      rm -rf "${volume_dir}"
      echo -e "$(gettext 'Cleaning up') ${CONFIG_DIR}"
      rm -rf "${CONFIG_DIR}"
      echo -e "$(gettext 'Cleaning up') /usr/bin/jmsctl"
      rm -f /usr/bin/jmsctl
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
  if [ -f "/etc/systemd/system/docker.service" ]; then
    echo
    confirm="n"
    read_from_input confirm "$(gettext 'Do you need to clean up the Docker binaries')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      systemctl stop docker
      systemctl disable docker
      systemctl daemon-reload
      echo -e "$(gettext 'Cleaning up') /usr/local/bin/docker"
      rm -f /usr/local/bin/docker*
      rm -f /usr/local/bin/container*
      rm -f /usr/local/bin/ctr
      rm -f /usr/local/bin/runc
      echo -e "$(gettext 'Cleaning up') /etc/systemd/system/docker.service"
      rm -f /etc/systemd/system/docker.service
    fi
    echo
  fi
  echo_green "$(gettext 'Cleanup complete')!"
}

function main() {
  echo_yellow "\n>>> $(gettext 'Uninstall JumpServer')"
  remove_jumpserver
  installation_log "uninstall"
}

main
