#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

function pre_install() {
  if ! command -v systemctl &>/dev/null; then
    docker version &>/dev/null || {
      log_error "$(gettext 'The current Linux system does not support systemd management. Please deploy docker by yourself before running this script again')"
      exit 1
    }
    docker compose version &>/dev/null || {
      log_error "$(gettext 'The current Linux system does not support systemd management. Please deploy docker-compose by yourself before running this script again')"
      exit 1
    }
  fi
  if ! command -v iptables &>/dev/null; then 
    log_error "Docker needs iptables. Please install iptables first."
    exit 1
  fi
  if command -v python&>/dev/null; then
    :
  elif command -v python2&>/dev/null; then
    :
  elif command -v python3&>/dev/null; then
    :
  else
    log_error "Docker compose needs python. Please install python first."
    exit 1
  fi
}

function post_install() {
  echo_green "\n>>> $(gettext 'The Installation is Complete')"
  host=$(get_host_ip)
  if [[ -z "${host}" ]]; then
    host="127.0.0.1"
  fi
  http_port=$(get_config HTTP_PORT)
  https_port=$(get_config HTTPS_PORT)
  server_name=$(get_config SERVER_NAME)
  ssh_port=$(get_config SSH_PORT)
  use_xpack=$(get_config_or_env USE_XPACK)

  echo_yellow "1. $(gettext 'You can use the following command to start, and then visit')"
  echo "cd ${PROJECT_DIR}"
  echo "./jmsctl.sh start"

  echo_yellow "\n2. $(gettext 'Other management commands')"
  echo "./jmsctl.sh stop"
  echo "./jmsctl.sh restart"
  echo "./jmsctl.sh backup"
  echo "./jmsctl.sh upgrade"
  echo "$(gettext 'For more commands, you can enter ./jmsctl.sh --help to understand')"

  echo_yellow "\n3. $(gettext 'Web access')"
  if [ -n "${server_name}" ] && [ -n "${https_port}" ]; then
    echo "https://${server_name}:${https_port}"
  else
    echo "http://${host}:${http_port}"
  fi

  echo "$(gettext 'Default username'): admin  $(gettext 'Default password'): ChangeMe"

  if [[ "${use_xpack}" == "1" ]]; then
    echo_yellow "\n4. SSH/SFTP $(gettext 'access')"
    echo "ssh -p${ssh_port} admin@${host}"
    echo "sftp -P${ssh_port} admin@${host}"
  fi

  echo_yellow "\n $(gettext 'More information')"
  echo "$(gettext 'Official Website'): https://www.jumpserver.org/"
  echo "$(gettext 'Documentation'): https://docs.jumpserver.org/"
  echo -e "\n"
}

function main() {
  echo_logo
  pre_install
  prepare_config
  set_current_version

  echo_green "\n>>> $(gettext 'Install and Configure Docker')"
  if ! bash "${BASE_DIR}/2_install_docker.sh"; then
    exit 1
  fi

  echo_green "\n>>> $(gettext 'Loading Docker Image')"
  if ! bash "${BASE_DIR}/3_load_images.sh"; then
    exit 1
  fi
  echo_green "\n>>> $(gettext 'Install and Configure JumpServer')"
  if ! bash "${BASE_DIR}/1_config_jumpserver.sh"; then
    exit 1
  fi
  installation_log "install"
  post_install
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
