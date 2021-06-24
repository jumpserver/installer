#!/usr/bin/env bash
#

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./util.sh
. "${BASE_DIR}/utils.sh"

function pre_install() {
  command -v systemctl &>/dev/null
  if [[ "$?" != "0" ]]; then
    command -v docker > /dev/null || {
      log_error "$(gettext 'The current Linux system does not support SYSTEMd management. Please deploy docker by yourself before running this script again')"
      exit 1
    }
    command -v docker-compose > /dev/null || {
      log_error "$(gettext 'The current Linux system does not support SYSTEMd management. Please deploy docker-compose by yourself before running this script again')"
      exit 1
    }
  fi
}

function post_install() {
  echo_green "\n>>> $(gettext 'The Installation is Complete')"
  HOST=$(ip addr | grep 'state UP' -A2 | grep inet | egrep -v '(127.0.0.1|inet6|docker)' | awk '{print $2}' | tr -d "addr:" | head -n 1 | cut -d / -f1)
  if [ ! "$HOST" ]; then
      HOST=$(hostname -I | cut -d ' ' -f1)
  fi
  HTTP_PORT=$(get_config HTTP_PORT)
  HTTPS_PORT=$(get_config HTTPS_PORT)
  SSH_PORT=$(get_config SSH_PORT)

  echo_yellow "1. $(gettext 'You can use the following command to start, and then visit')"
  echo "./jmsctl.sh start"

  echo_yellow "\n2. $(gettext 'Other management commands')"
  echo "./jmsctl.sh stop"
  echo "./jmsctl.sh restart"
  echo "./jmsctl.sh backup"
  echo "./jmsctl.sh upgrade"
  echo "$(gettext 'For more commands, you can enter ./jmsctl.sh --help to understand')"

  echo_yellow "\n3. $(gettext 'Web access')"
  echo "http://${HOST}:${HTTP_PORT}"

  use_lb=$(get_config USE_LB)
  if [[ "${use_lb}" == "1" ]]; then
    echo "https://${HOST}:${HTTPS_PORT}"
  fi
  echo "$(gettext 'Default username'): admin  $(gettext 'Default password'): admin"

  echo_yellow "\n4. SSH/SFTP $(gettext 'access')"
  echo "ssh -p${SSH_PORT} admin@${HOST}"
  echo "sftp -P${SSH_PORT} admin@${HOST}"

  echo_yellow "\n5. $(gettext 'More information')"
  echo "$(gettext 'Offical Website'): https://www.jumpserver.org/"
  echo "$(gettext 'Documentation'): https://docs.jumpserver.org/"
  echo -e "\n"
}

function set_lang() {
  # 安装默认不会为中文，所以直接用中文
  if [[ "${LANG-''}" == "zh_CN.UTF-8" ]]; then
    return
  fi
  # 设置过就不用改了
  if grep "export LANG=" ~/.bashrc &> /dev/null; then
    return
  fi
  lang="cn"
  read_from_input lang "语言 Language " "cn/en" "${lang}"
  LANG='zh_CN.UTF-8'
  if [[ "${lang}" == "en" ]]; then
    LANG='en_US.UTF-8'
  fi
  echo "export LANG=${LANG}" >> ~/.bashrc
  # 之所以这么设置，是因为设置完 ~/.bashrc，就不会再询问，然而 LANG 环境变量，在用户当前 bash 进程中不生效
  echo "export LANG=${LANG}" >> "${PROJECT_DIR}"/static.env
  export LANG
}

function main() {
  echo_logo
  set_lang
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
  post_install
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
