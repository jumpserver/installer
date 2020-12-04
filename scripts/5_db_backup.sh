#!/bin/bash
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR=$(dirname ${BASE_DIR})
# shellcheck source=./util.sh
source "${BASE_DIR}/utils.sh"
BACKUP_DIR=/opt/jumpserver/db_backup

HOST=$(get_config DB_HOST)
PORT=$(get_config DB_PORT)
USER=$(get_config DB_USER)
PASSWORD=$(get_config DB_PASSWORD)
DATABASE=$(get_config DB_NAME)
DB_FILE=${BACKUP_DIR}/jumpserver-`date +%F_%T`.sql
DB_FILE_ZIP=${DB_FILE}.gz

mkdir -p ${BACKUP_DIR}

echo_green "\n>>> 开始备份数据库"
echo "正在备份..."
backup_cmd="mysqldump --host=${HOST} --port=${PORT} --user=${USER} --password=${PASSWORD} ${DATABASE}"
docker run --rm -i --network=jms_net jumpserverpublic/mysql:5 ${backup_cmd} | gzip > ${DB_FILE_ZIP}

code="x$?"
if [[ "$code" != "x0" ]];then
    echo -e "\033[31m备份失败!\033[0m"
    rm -f "${DB_FILE_ZIP}"
    exit 1
else    
    echo -e "\033[32m备份成功! 备份文件已存放至: ${DB_FILE_ZIP} \033[0m"
fi

