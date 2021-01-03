#!/usr/bin/env bash
set -ue

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./util.sh
source "${BASE_DIR}/utils.sh"

function pre_install() {
  echo
}

function post_install() {
  echo_green "\n>>> $(gettext -s 'The Installation is Complete')"
  HOST=$(ip addr | grep 'state UP' -A2 | grep inet | egrep -v '(127.0.0.1|inet6|docker)' | awk '{print $2}' | tr -d "addr:" | head -n 1 | cut -d / -f1)
  if [ ! "$HOST" ]; then
      HOST=$(hostname -I | cut -d ' ' -f1)
  fi
  HTTP_PORT=$(get_config HTTP_PORT)
  HTTPS_PORT=$(get_config HTTPS_PORT)
  SSH_PORT=$(get_config SSH_PORT)

  echo_yellow "\n1. $(gettext -s 'You can use the following command to start, and then access')"
  echo "./jmsctl.sh start"

  echo_yellow "\n2. $(gettext -s 'Other management commands')"
  echo "./jmsctl.sh stop"
  echo "./jmsctl.sh restart"
  echo "./jmsctl.sh backup"
  echo "./jmsctl.sh upgrade"
  echo "$(gettext -s 'There are more orders, you can ./jmsctl.sh --help to understand')"

  echo_yellow "\n3. $(gettext -s 'Web access')"
  echo "http://${HOST}:${HTTP_PORT}"
  echo "https://${HOST}:${HTTPS_PORT}"
  echo "$(gettext -s 'Default user'): admin  $(gettext -s 'Default password'): admin"

  echo_yellow "\n4. SSH/SFTP $(gettext -s 'access')"
  echo "ssh admin@${HOST} -p${SSH_PORT}"
  echo "sftp -P${SSH_PORT} admin@${HOST}"

  echo_yellow "\n5. $(gettext -s 'More information')"
  echo "$(gettext -s 'Our website'): https://www.jumpserver.org/"
  echo "$(gettext -s 'Our documents'): https://docs.jumpserver.org/"
  echo -e "\n\n"
}

function main() {
  echo_logo
  pre_install
  echo_green "\n>>> $(gettext -s 'Install and Configure JumpServer')"
  (bash "${BASE_DIR}/1_config_jumpserver.sh")
  echo_green "\n>>> $(gettext -s 'Install and Configure Docker')"
  (bash "${BASE_DIR}/2_install_docker.sh")
  echo_green "\n>>> $(gettext -s 'Loading Docker Image')"
  (bash "${BASE_DIR}/3_load_images.sh")
  post_install
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
