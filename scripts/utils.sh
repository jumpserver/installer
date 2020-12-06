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
  docker run -it --rm registry.fit2cloud.com/jumpserver/mysql:5 mysql -h${host} -P${port} -u${user} -p${password} ${db} -e "${command}" 2>/dev/null
}

function test_redis_connect() {
  host=$1
  port=$2
  password=$3
  password=${password:=''}
  docker run -it --rm registry.fit2cloud.com/jumpserver/redis:alpine redis-cli -h "${host}" -p "${port}" -a "${password}" info | grep "redis_version" >/dev/null
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
    echo "jumpserver/xpack:${VERSION}"
    echo "jumpserver/omnidb:${VERSION}"
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

function log_success() {
  echo_green "[SUCCESS] $1"
}

function log_warn() {
  echo_yellow "[WARN] $1"
}

function log_error() {
  echo_red "[ERROR] $1"
}
