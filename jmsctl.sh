#!/bin/bash
BASE_DIR=$(
  cd "$(dirname "$0")"
  pwd
)
# shellcheck source=scripts/utils.sh
source "${BASE_DIR}/scripts/utils.sh"
SCRIPT_DIR=${BASE_DIR}/scripts
STATIC_ENV='static.env'
# shellcheck source=static.env
source "${STATIC_ENV}"
action=${1-}
target=${2-}
args="$@"

function upgrade() {
  bash "${SCRIPT_DIR}/5_db_backup.sh"
  if [[ "$?" != "0" ]]; then
    echo "备份数据库失败, 确认成功后可以继续执行一下操作"
  else
    echo "备份数据库完成, 接下来"
  fi
  echo "1. 下载新的release包，解压，然后在新下载的release包中执行 ./jmsctl.sh load_image 加载新的镜像"
  echo "2. 然后直接启动 ./jmsctl.sh start"
}

function copy_coco_to_koko() {
  volume_dir=$(get_config VOLUME_DIR)
  coco_dir="${volume_dir}/coco"
  koko_dir="${volume_dir}/koko"
  if [[ ! -d "${koko_dir}" && -d "${coco_dir}" ]]; then
    mv ${coco_dir} ${koko_dir}
    ln -s ${koko_dir} ${coco_dir}
  fi
}

function migrate_config() {
  if [[ -f config.txt && ! -f ${CONFIG_FILE} ]]; then
    mkdir -p "$(dirname ${CONFIG_FILE})"
    mv config.txt ${CONFIG_FILE}
    rm -f .env
    ln -s ${CONFIG_FILE} .env
    ln -s ${CONFIG_FILE} config.link
  fi
  if [[ ! -d /opt/jumpserver/config/nginx ]]; then
    mkdir -p /opt/jumpserver/config/
    cp -R nginx /opt/jumpserver/config/
  fi
  if [[ -f config.txt ]]; then
    mv config.txt config.txt."$(date '+%s')"
  fi
}

function check_config_file() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Config file not found: ${CONFIG_FILE};"
    return 3
  fi
}

function check_env_file() {
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
  copy_coco_to_koko
  # 迁移config文件
  migrate_config

  check_config_file || return 3
  check_env_file || return 4
}

function get_docker_compose_cmd_line() {
  cmd="docker-compose -f compose/docker-compose-app.yml "
  use_ipv6=$(get_config USE_IPV6)
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-network.yml "
  else
    cmd="${cmd} -f compose/docker-compose-network_ipv6.yml "
  fi
  use_task=$(get_config USE_TASK)
  if [[ "${use_task}" != "0" ]]; then
    cmd="${cmd} -f compose/docker-compose-task.yml"
  fi
  use_external_mysql=$(get_config USE_EXTERNAL_MYSQL)
  if [[ "${use_external_mysql}" != "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-mysql.yml"
  fi
  use_external_redis=$(get_config USE_EXTERNAL_REDIS)
  if [[ "${use_external_redis}" != "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-redis.yml"
  fi
  use_lb=$(get_config USE_LB)
  if [[ "${use_lb}" == "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-lb.yml"
  fi
  use_xpack=$(get_config USE_XPACK)
  if [[ "${use_xpack}" == "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-xpack.yml -f compose/docker-compose-omnidb.yml"
  fi
  echo ${cmd}
}

function usage() {
  echo "JumpServer 部署安装脚本"
  echo
  echo "Usage: "
  echo "  ./jmsctl.sh [COMMAND] [ARGS...]"
  echo "  ./jmsctl.sh --help"
  echo
  echo "Commands: "
  echo "  install 部署安装JumpServer"
  echo "  reconfig 配置JumpServer"
  echo "  upgrade 升级JumpServer说明"
  echo "  backup_db 备份数据库"
  echo "  restore_db [db_file] 通过数据库备份文件恢复数据库数据"
  echo "  load_image 重新加载镜像"
  echo "  start 启动JumpServer"
  echo "  restart [service] 重启, 并不会重建服务容器"
  echo "  reload [service] 重建容器如何需要并重启服务"
  echo "  status 查看JumpServer状态"
  echo "  down [service] 删掉容器 不带参数删掉所有"
  echo "  python 进入core, 运行 python manage.py shell"
  echo "  db 连接数据库"
  echo "  ... 其他docker-compose执行的命令 如 logs 等等"
}

function service_to_docker_name() {
  service=$1
  if [[ "${service:0:3}" != "jms" ]]; then
    service=jms_${service}
  fi
  echo ${service}
}

function main() {
  EXE=""
  if [[ "${action}" != "install" && "${action}" != "reconfig" ]]; then
    pre_check || return 3
    EXE=$(get_docker_compose_cmd_line)
  fi
  case "${action}" in
  reconfig)
    bash ${SCRIPT_DIR}/3_config_jumpserver.sh
    ;;
  install)
    bash ${SCRIPT_DIR}/4_install_jumpserver.sh
    ;;
  upgrade)
    bash ${SCRIPT_DIR}/8_upgrade.sh $target
    ;;
  backup_db)
    bash ${SCRIPT_DIR}/5_db_backup.sh
    ;;
  restore_db)
    bash ${SCRIPT_DIR}/6_db_restore.sh $target
    ;;
  load_image)
    bash ${SCRIPT_DIR}/2_load_images.sh
    ;;
  start)
    ${EXE} up -d
    ;;
  restart)
    ${EXE} restart ${target}
    ;;
  reload)
    ${EXE} up -d &>/dev/null
    ${EXE} restart ${target}
    ;;
  status)
    ${EXE} ps
    ;;
  cmd)
    echo ${EXE}
    ;;
  down)
    if [[ -z "${target}" ]]; then
      ${EXE} down
    else
      ${EXE} stop ${target} && ${EXE} rm ${target}
    fi
    ;;
  tail)
    if [[ -z "${target}" ]]; then
      ${EXE} logs --tail 100 -f
    else
      docker_name=$(service_to_docker_name ${target})
      docker logs -f ${docker_name} --tail 100
    fi
    ;;
  python)
    docker exec -it jms_core python /opt/jumpserver/apps/manage.py shell
    ;;
  db)
    docker exec -it jms_core python /opt/jumpserver/apps/manage.py dbshell
    ;;
  exec)
    docker_name=$(service_to_docker_name ${target})
    docker exec -it ${docker_name} sh
    ;;
  backup)
    bash ${SCRIPT_DIR}/5_db_backup.sh
    bash ${SCRIPT_DIR}/7_images_backup.sh backup
    ;;
  help)
    usage
    ;;
  cmdline)
    echo ${EXE}
    ;;
  --help)
    usage
    ;;
  *)
    ${EXE} ${args}
    ;;
  esac
}

main
