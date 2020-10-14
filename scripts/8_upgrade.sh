#!/usr/bin/env bash
BASE_DIR=$(dirname "$0")
#BASE_DIR=$(cd "$(dirname "$0")";pwd)
PROJECT_DIR=${BASE_DIR}
SCRIPT_DIR=${BASE_DIR}/scripts
source ${BASE_DIR}/utils.sh
target=$1

function main() {
    bash ${SCRIPT_DIR}/5_db_backup.sh
    echo ">>> 接下来:"
    echo "1. 下载新的release包，然后再新下载的release包中执行 ./jmsctl.sh load_image"
    echo "2. 然后在回到当前目录启动 ./jmsctl.sh start"
}

main