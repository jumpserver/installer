#!/usr/bin/env bash
set -ue

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./util.sh
source "${BASE_DIR}/utils.sh"

function pre_install() {
  echo
}

function post_install() {
  echo_green "\n>>> 四、安装完成了"
  HOST=$(ip addr | grep 'state UP' -A2 | grep inet | egrep -v '(127.0.0.1|inet6|docker)' | awk '{print $2}' | tr -d "addr:" | head -n 1 | cut -d / -f1)
  if [ ! "$HOST" ]; then
      HOST=$(hostname -I | cut -d ' ' -f1)
  fi
  HTTP_PORT=$(get_config HTTP_PORT)
  HTTPS_PORT=$(get_config HTTPS_PORT)
  SSH_PORT=$(get_config SSH_PORT)

  echo_yellow "1. 可以使用如下命令启动, 然后访问"
  echo "./jmsctl.sh start"

  echo_yellow "\n2. 其它一些管理命令"
  echo "./jmsctl.sh stop"
  echo "./jmsctl.sh restart"
  echo "./jmsctl.sh backup"
  echo "./jmsctl.sh upgrade"
  echo "更多还有一些命令，你可以 ./jmsctl.sh --help 来了解"

  echo_yellow "\n3. 访问 Web 后台页面"
  echo "http://${HOST}:${HTTP_PORT}"
  echo "https://${HOST}:${HTTPS_PORT}"
  echo "默认用户: admin  默认密码: admin"

  echo_yellow "\n4. ssh/sftp 访问"
  echo "ssh admin@${HOST} -p${SSH_PORT}"
  echo "sftp -P${SSH_PORT} admin@${HOST}"

  echo_yellow "\n5. 更多信息"
  echo "我们的文档: https://docs.jumpserver.org/"
  echo "我们的官网: https://www.jumpserver.org/"
  echo -e "\n\n"
}

function main() {
  echo_logo
  pre_install
  echo_green "\n>>> 一、配置 JumpServer"
  (bash "${BASE_DIR}/1_config_jumpserver.sh")
  echo_green "\n>>> 二、安装配置 Docker"
  (bash "${BASE_DIR}/2_install_docker.sh")
  echo_green "\n>>> 三、加载镜像"
  (bash "${BASE_DIR}/3_load_images.sh")
  post_install
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
