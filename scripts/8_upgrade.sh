#!/usr/bin/env bash
BASE_DIR=$(dirname "$0")
#BASE_DIR=$(cd "$(dirname "$0")";pwd)
PROJECT_DIR=${BASE_DIR}
SCRIPT_DIR=${BASE_DIR}/scripts
source ${BASE_DIR}/utils.sh
target=$1

function main() {
    bash ${SCRIPT_DIR}/5_db_backup.sh
    if [[ "$?" != "0" ]]; then
      echo "备份数据库失败, 确认成功后可以继续执行一下操作"
    else
      echo "备份数据库完成, 接下来"
    fi
    echo "1. 下载新的release包，解压，然后在新下载的release包中执行 ./jmsctl.sh load_image 加载新的镜像"
    echo "2. 然后直接启动 ./jmsctl.sh start"
}

main
