#!/usr/bin/env bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# shellcheck source=./const.sh
source "${BASE_DIR}/const.sh"

function is_confirm() {
  read -r confirmed
  if [[ "${confirmed}" == "y" || "${confirmed}" == "Y" || ${confirmed} == "" ]]; then
    return 0
  else
    return 1
  fi
}


function random_str() {
  len=$1
  if [[ -z ${len} ]]; then
    len=16
  fi
  command -v ifconfig &>/dev/null
  if [[ "$?" == "0" ]]; then
    cmd=ifconfig
  else
    cmd="ip a"
  fi
  sh -c "${cmd}" | tail -10 | base64 | head -c ${len}
}

function get_config() {
  cwd=$(pwd)
  cd "${PROJECT_DIR}" || exit
  key=$1
  value=$(grep "^${key}=" ${CONFIG_FILE} | awk -F= '{ print $2 }')
  echo "${value}"
  cd "${cwd}" || exit
}

function set_config() {
  cwd=$(pwd)
  cd "${PROJECT_DIR}" || exit
  key=$1
  value=$2
  if [[ "${OS}" == 'Darwin' ]]; then
    sed -i '' "s,^${key}=.*$,${key}=${value},g" ${CONFIG_FILE}
  else
    sed -i "s,^${key}=.*$,${key}=${value},g" ${CONFIG_FILE}
  fi
  cd "${cwd}" || exit
}

function test_mysql_connect() {
  host=$1
  port=$2
  user=$3
  password=$4
  db=$5
  command="CREATE TABLE IF NOT EXISTS test(id INT); DROP TABLE test;"
  docker run -it --rm jumpserver/mysql:5 mysql -h${host} -P${port} -u${user} -p${password} ${db} -e "${command}" 2>/dev/null
}

function test_redis_connect() {
  host=$1
  port=$2
  password=$3
  password=${password:=''}
  docker run -it --rm jumpserver/redis:alpine redis-cli -h "${host}" -p "${port}" -a "${password}" info | grep "redis_version" >/dev/null
}

function get_images() {
  scope="all"
  if [[ ! -z "$1" ]]; then
    scope="$1"
  fi
  images=(
    "jumpserver/redis:alpine"
    "jumpserver/mysql:5"
    "jumpserver/nginx:alpine2"
    "jumpserver/luna:${VERSION}"
    "jumpserver/core:${VERSION}"
    "jumpserver/koko:${VERSION}"
    "jumpserver/guacamole:${VERSION}"
    "jumpserver/lina:${VERSION}"
  )
  for image in "${images[@]}"; do
    echo "${image}"
  done
  if [[ "${scope}" == "all" ]]; then
    echo "registry.fit2cloud.com/jumpserver/xpack:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/omnidb:${VERSION}"
  fi
}

function read_from_input() {
  var=$1
  msg=$2
  choices=$3
  default=$4
  if [[ ! -z "${choices}" ]]; then
    msg="${msg} (${choices}) "
  fi
  if [[ -z "${default}" ]]; then
    msg="${msg} (无默认值)"
  else
    msg="${msg} (默认为${default})"
  fi
  echo -n "${msg}: "
  read input
  if [[ -z "${input}" && ! -z "${default}" ]]; then
    export ${var}="${default}"
  else
    export ${var}="${input}"
  fi
}

function get_file_md5() {
  file_path=$1
  if [[ -f "${file_path}" ]]; then
    if [[ "${OS}" == "Darwin" ]]; then
      md5 "${file_path}" | awk -F= '{ print $2 }'
    else
      md5sum "${file_path}" | awk '{ print $1 }'
    fi
  fi
}

function check_md5() {
  file=$1
  md5_should=$2

  md5=$(get_file_md5 "${file}")
  if [[ "${md5}" == "${md5_should}" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function is_running() {
  ps axu | grep -v grep | grep $1 &>/dev/null
  if [[ "$?" == "0" ]]; then
    echo 1
  else
    echo 0
  fi
}

function echo_red() {
  echo -e "\033[1;31m$1\033[0m"
}

function echo_green() {
  echo -e "\033[1;32m$1\033[0m"
}

function echo_yellow() {
  echo -e "\033[1;33m$1\033[0m"
}

function echo_done() {
  sleep 0.5
  echo "完成"
}

function echo_failed() {
  echo_red "失败"
}

function log_success() {
  echo_green "[SUCCESS] $1"
}

function log_warn() {
  echo_yellow "[WARN] $1"
}

function log_error() {
  echo_red "[ERROR] $1"
}

function get_docker_compose_services() {
  ignore_db="$1"
  services="core koko guacamole lina luna nginx"
  use_task=$(get_config USE_TASK)
  if [[ "${use_task}" != "0" ]]; then
    services+=" celery"
  fi
  use_external_mysql=$(get_config USE_EXTERNAL_MYSQL)
  if [[ "${use_external_mysql}" != "1" && "${ignore_db}" != "ignore_db" ]]; then
    services+=" mysql"
  fi
  use_external_redis=$(get_config USE_EXTERNAL_REDIS)
  if [[ "${use_external_redis}" != "1" && "${ignore_db}" != "ignore_db" ]]; then
    services+=" redis"
  fi
  use_lb=$(get_config USE_LB)
  if [[ "${use_lb}" == "1" ]]; then
    services+=" lb"
  fi
  use_xpack=$(get_config USE_XPACK)
  if [[ "${use_xpack}" == "1" ]]; then
    services+=" xpack omnidb"
  fi
  echo "${services}"
}

function get_docker_compose_cmd_line() {
  ignore_db="$1"
  cmd="docker-compose -f ./compose/docker-compose-app.yml "
  use_ipv6=$(get_config USE_IPV6)
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-network.yml "
  else
    cmd="${cmd} -f compose/docker-compose-network_ipv6.yml "
  fi
  services=$(get_docker_compose_services "$ignore_db")
  if [[ "${services}" =~ celery ]]; then
    cmd="${cmd} -f ./compose/docker-compose-task.yml"
  fi
  if [[ "${services}" =~ mysql ]]; then
    cmd="${cmd} -f ./compose/docker-compose-mysql.yml"
  fi
  if [[ "${services}" =~ redis ]]; then
    cmd="${cmd} -f ./compose/docker-compose-redis.yml"
  fi
  if [[ "${services}" =~ lb ]]; then
    cmd="${cmd} -f ./compose/docker-compose-lb.yml"
  fi
  if [[ "${services}" =~ xpack ]]; then
    cmd="${cmd} -f ./compose/docker-compose-xpack.yml"
  fi
  if [[ "${services}" =~ omnidb ]];then
    cmd="${cmd} -f ./compose/docker-compose-omnidb.yml"
  fi
  echo "${cmd}"
}

function prepare_online_install_required_pkg() {
  command -v wget &>/dev/null || yum -y install wget
  command -v zip &>/dev/null || yum -y install zip
}

function echo_logo() {
  cat <<"EOF"

       ██╗██╗   ██╗███╗   ███╗██████╗ ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗
       ██║██║   ██║████╗ ████║██╔══██╗██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗
       ██║██║   ██║██╔████╔██║██████╔╝███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝
  ██   ██║██║   ██║██║╚██╔╝██║██╔═══╝ ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗
  ╚█████╔╝╚██████╔╝██║ ╚═╝ ██║██║     ███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║
  ╚════╝  ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝

EOF

  echo -e "\t\t\t\t\t\t\t\t\t Version: \033[33m $VERSION \033[0m \n"
}

function get_latest_version() {
  curl -s 'https://api.github.com/repos/jumpserver/jumpserver/releases/latest' |
    grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' |
    sed 's/\"//g;s/,//g;s/ //g'
}


function image_has_prefix() {
  if [[ $1 =~ registry.* ]];then
    echo "1"
  else
    echo "0"
  fi
}

function perform_db_migrations() {
  docker run -it --rm --network=jms_net \
    --env-file=/opt/jumpserver/config/config.txt \
    jumpserver/core:"${VERSION}" upgrade_db
}

function check_ipv6_iptables_if_need() {
  # 检查 IPv6
  use_ipv6=$(get_config USE_IPV6)
  subnet_ipv6=$(get_config DOCKER_SUBNET_IPV6)
  if [[ "${use_ipv6}" != "1" ]];then
    if ! ip6tables -t nat -L | grep "${subnet_ipv6}"; then
        ip6tables -t nat -A POSTROUTING -s "${subnet_ipv6}" -j MASQUERADE
    fi
  fi
}