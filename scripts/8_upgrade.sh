#!/usr/bin/env bash
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
#BASE_DIR=$(cd "$(dirname "$0")";pwd)
# shellcheck source=./util.sh
source "${BASE_DIR}/utils.sh"
source "${BASE_DIR}/1_install_docker.sh"

target=$1


function perform_db_migrations() {
   echo
}


function update_config_if_need() {
   echo
}


function update_proc_if_need() {
  install_docker
}


function main() {
  echo_yellow "1. 备份数据库"
  bash ${SCRIPT_DIR}/5_db_backup.sh

  if [[ "$?" != "0" ]];then
    read_from_input confirm "备份数据库失败, 继续升级吗?" "Yes/no" "no"
    if [[ "${confirm}" == "no" ]];then
      exit 1
    fi
  fi

  echo_yellow "\n2. 检查配置文件变更"
  update_config_if_need

  echo_yellow "\n3. 检查程序文件变更"
  update_proc_if_need

  echo_yellow "\n4. 升级镜像文件"
  bash ${SCRIPT_DIR}/2_load_images.sh

  if [[ "$?" != "0" ]];then
    echo_read "升级镜像失败, 取消升级"
    exit 2
  fi

  echo_yellow "\n5. 进行数据库变更"
  echo "表结构变更可能需要一段时间，请耐心等待"
  docker run -it --rm jumpserver/core:${VERSION} upgrade:

  echo "1. 下载新的release包，解压，然后在新下载的release包中执行 ./jmsctl.sh load_image 加载新的镜像"
  echo "2. 然后直接启动 ./jmsctl.sh start"
}

case $1 in
run)
  main
  ;;
esac
