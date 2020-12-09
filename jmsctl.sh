#!/bin/bash

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=scripts/utils.sh
source "${PROJECT_DIR}/scripts/utils.sh"

action=${1-}
target=${2-}
args="$@"

function check_config_file() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Config file not found: ${CONFIG_FILE};"
    return 3
  fi
  if [[ -f .env ]]; then
    ls -l .env | grep "${CONFIG_FILE}" &>/dev/null
    code="$?"
    if [[ "$code" != "0" ]]; then
      echo ".env link error, change it"
      rm -f .env
    fi
  fi

  if [[ ! -f .env ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi
}

function pre_check() {
  check_config_file || return 3
}

function usage() {
  echo "JumpServer 部署管理脚本"
  echo
  echo "Usage: "
  echo "  ./jmsctl.sh [COMMAND] [ARGS...]"
  echo "  ./jmsctl.sh --help"
  echo
  echo "Commands: "
  echo "  install    安装 JumpServer"
  echo "  start      启动 JumpServer"
  echo "  stop       停止 JumpServer(不停数据库)"
  echo "  restart    重启 JumpServer"
  echo "  status     检查 JumpServer"
  echo "  down       下线 JumpServer(会停数据库)"
  echo "  upgrade    升级 JumpServer"
  echo "  reconfig   配置 JumpServer"
  echo
  echo "Management Commands: "
  echo "  load_image           加载 docker 镜像"
  echo "  python               运行 python manage.py shell"
  echo "  db                   运行 python manage.py dbshell"
  echo "  backup_db            备份 数据库"
  echo "  restore_db [db_file] 通过 数据库备份文件恢复数据"

}

function service_to_docker_name() {
  service=$1
  if [[ "${service:0:3}" != "jms" ]]; then
    service=jms_${service}
  fi
  echo "${service}"
}

function main() {
  EXE=""
  if [[ "${action}" == "help" || "${action}" == "h" || "${action}" == "-h" || "${action}" == "--help" ]]; then
    echo ""
  elif [[ "${action}" != "install" && "${action}" != "reconfig" ]]; then
    pre_check || return 3
    EXE=$(get_docker_compose_cmd_line)
  fi
  case "${action}" in
  reconfig)
    bash "${SCRIPT_DIR}/3_config_jumpserver.sh"
    ;;
  install)
    bash "${SCRIPT_DIR}/4_install_jumpserver.sh"
    ;;
  upgrade)
    bash "${SCRIPT_DIR}/8_upgrade.sh" "$target"
    ;;
  backup_db)
    bash "${SCRIPT_DIR}/5_db_backup.sh"
    ;;
  restore_db)
    bash "${SCRIPT_DIR}/6_db_restore.sh" "$target"
    ;;
  load_image)
    bash "${SCRIPT_DIR}/2_load_images.sh"
    ;;
  start)
    ${EXE} up -d
    ;;
  restart)
    ${EXE} restart "${target}"
    ;;
  reload)
    ${EXE} up -d &>/dev/null
    ${EXE} restart "${target}"
    ;;
  status)
    ${EXE} ps
    ;;
  cmd)
    echo "${EXE}"
    ;;
  stop)
    if [[ -n "${target}" ]]; then
      ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
      return
    fi
    services=$(get_docker_compose_services ignore_db)
    for i in ${services}; do
      ${EXE} stop "${i}" && ${EXE} rm -f "${i}" > /dev/null
    done
    docker volume rm jms_share-volume &> /dev/null
    ;;
  down)
    if [[ -z "${target}" ]]; then
      ${EXE} down
    else
      ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
    fi
    ;;
  tail)
    if [[ -z "${target}" ]]; then
      ${EXE} logs --tail 100 -f
    else
      docker_name=$(service_to_docker_name "${target}")
      docker logs -f "${docker_name}" --tail 100
    fi
    ;;
  python)
    docker exec -it jms_core python /opt/jumpserver/apps/manage.py shell
    ;;
  db)
    docker exec -it jms_core python /opt/jumpserver/apps/manage.py dbshell
    ;;
  exec)
    docker_name=$(service_to_docker_name "${target}")
    docker exec -it "${docker_name}" sh
    ;;
  help)
    usage
    ;;
  cmdline)
    echo "${EXE}"
    ;;
  --help)
    usage
    ;;
  -h)
    usage
    ;;
  *)
    echo "No such command: ${action}"
    usage
    ;;
  esac
}

main
