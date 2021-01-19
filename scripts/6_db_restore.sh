#!/bin/bash
# coding: utf-8

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

DB_FILE="$1"

function main() {
  echo "开始还原数据库: $DB_FILE"
  restore_cmd="mysql --host=${HOST} --port=${PORT} --user=${USER} --password=${PASSWORD} ${DATABASE}"

  if [[ ! -f "${DB_FILE}" ]]; then
    echo "文件不存在: ${DB_FILE}"
    exit 2
  fi

  if [[ "${DB_FILE}" == *".gz" ]]; then
    gunzip <${DB_FILE} | docker run --rm -i --network=jms_net jumpserver/mysql:5 ${restore_cmd}
  else
    docker run --rm -i --network=jms_net jumpserver/mysql:5 $restore_cmd <"${DB_FILE}"
  fi
  code="x$?"
  if [[ "$code" != "x0" ]]; then
    echo -e "\033[31m 数据库恢复失败,请检查数据库文件是否完整，或尝试手动恢复！\033[0m"
    exit 1
  else
    echo -e "\033[32m 数据库恢复成功！ \033[0m"
  fi
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  if [[ -z "$1" ]]; then
    echo "格式错误！Usage './jmsctl.sh restore_db DB_Backup_file '"
    exit 1
  fi
  if [[ ! -f $1 ]];then
    echo "备份文件不存在: $1"
    exit 2
  fi
  main
fi
