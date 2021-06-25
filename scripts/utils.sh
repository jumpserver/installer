#!/usr/bin/env bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# shellcheck source=./const.sh
. "${BASE_DIR}/const.sh"

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
  uuid=None
  if command -v dmidecode &>/dev/null; then
    uuid=$(dmidecode -t 1 | grep UUID | awk '{print $2}' | base64 | head -c ${len})
  fi
  if [[ "$(echo $uuid | wc -L)" == "${len}" ]]; then
    echo ${uuid}
  else
    cat /dev/urandom | tr -dc A-Za-z0-9 | head -c ${len}; echo
  fi
}

function has_config() {
  key=$1
  if grep "^${key}=" "${CONFIG_FILE}" &>/dev/null; then
    echo "1"
  else
    echo "0"
  fi
}

function get_config() {
  key=$1
  value=$(grep "^${key}=" "${CONFIG_FILE}" | awk -F= '{ print $2 }')
  echo "${value}"
}

function set_config() {
  key=$1
  value=$2

  has=$(has_config "${key}")
  if [[ ${has} == "0" ]]; then
    echo "${key}=${value}" >>"${CONFIG_FILE}"
    return
  fi

  origin_value=$(get_config "${key}")
  if [[ "${value}" == "${origin_value}" ]]; then
    return
  fi

  if [[ "${OS}" == 'Darwin' ]]; then
    sed -i '' "s,^${key}=.*$,${key}=${value},g" "${CONFIG_FILE}"
  else
    sed -i "s,^${key}=.*$,${key}=${value},g" "${CONFIG_FILE}"
  fi
}

function test_mysql_connect() {
  host=$1
  port=$2
  user=$3
  password=$4
  db=$5
  command="CREATE TABLE IF NOT EXISTS test(id INT); DROP TABLE test;"
  docker run -i --rm jumpserver/mariadb:10 mysql -h${host} -P${port} -u${user} -p${password} ${db} -e "${command}" 2>/dev/null
}

function test_redis_connect() {
  host=$1
  port=$2
  password=$3
  password=${password:=''}
  docker run -i --rm jumpserver/redis:6-alpine redis-cli -h "${host}" -p "${port}" -a "${password}" info | grep "redis_version" >/dev/null
}

function get_images() {
  scope="all"
  if [[ ! -z "$1" ]]; then
    scope="$1"
  fi
  images=(
    "jumpserver/redis:6-alpine"
    "jumpserver/mariadb:10"
    "jumpserver/nginx:alpine2"
    "jumpserver/luna:${VERSION}"
    "jumpserver/core:${VERSION}"
    "jumpserver/koko:${VERSION}"
    "jumpserver/lion:${VERSION}"
    "jumpserver/lina:${VERSION}"
  )
  for image in "${images[@]}"; do
    echo "${image}"
  done
  if [[ "${scope}" == "all" ]]; then
    echo "registry.jumpserver.org/jumpserver/xpack:${VERSION}"
    echo "registry.jumpserver.org/jumpserver/omnidb:${VERSION}"
    echo "registry.jumpserver.org/jumpserver/xrdp:${VERSION}"
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
    msg="${msg} ($(gettext 'no default'))"
  else
    msg="${msg} ($(gettext 'default') ${default})"
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
  echo "$(gettext 'complete')"
}

function echo_failed() {
  echo_red "$(gettext 'fail')"
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
  services="core koko lion lina luna nginx"
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
    services+=" xpack omnidb xrdp"
  fi
  echo "${services}"
}

function get_docker_compose_cmd_line() {
  ignore_db="$1"
  cmd="docker-compose -f ./compose/docker-compose-app.yml"
  use_ipv6=$(get_config USE_IPV6)
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-network.yml"
  else
    cmd="${cmd} -f compose/docker-compose-network_ipv6.yml"
  fi
  services=$(get_docker_compose_services "$ignore_db")
  if [[ "${services}" =~ celery ]]; then
    cmd="${cmd} -f ./compose/docker-compose-task.yml"
  fi
  if [[ "${services}" =~ mysql ]]; then
    db_host=$(get_config DB_HOST)
    if [[ "${db_host}" == "mysql" ]]; then
      cmd="${cmd} -f ./compose/docker-compose-mysql.yml -f ./compose/docker-compose-mysql-internal.yml"
    else
      cmd="${cmd} -f ./compose/docker-compose-mariadb.yml -f ./compose/docker-compose-mariadb-internal.yml"
    fi
  fi
  if [[ "${services}" =~ redis ]]; then
    cmd="${cmd} -f ./compose/docker-compose-redis.yml -f ./compose/docker-compose-redis-internal.yml"
  fi
  if [[ "${services}" =~ lb ]]; then
    cmd="${cmd} -f ./compose/docker-compose-lb.yml"
  else
    cmd="${cmd} -f ./compose/docker-compose-external.yml"
  fi
  if [[ "${services}" =~ xpack ]]; then
      cmd="${cmd} -f ./compose/docker-compose-xpack.yml"
      if [[ "${services}" =~ lb ]]; then
        cmd="${cmd} -f ./compose/docker-compose-lb-xpack.yml"
      else
        cmd="${cmd} -f ./compose/docker-compose-xpack-external.yml"
      fi
  fi
  echo "${cmd}"
}

function install_required_pkg() {
  required_pkg=$1
  if command -v dnf > /dev/null; then
    if [ "$required_pkg" == "python" ]; then
      dnf -q -y install python2
      ln -s /usr/bin/python2 /usr/bin/python
    else
      dnf -q -y install $required_pkg
    fi
  elif command -v yum > /dev/null; then
    yum -q -y install $required_pkg
  elif command -v apt > /dev/null; then
    apt-get -qq -y install $required_pkg
  elif command -v zypper > /dev/null; then
    zypper -q -n install $required_pkg
  elif command -v apk > /dev/null; then
    if [ "$required_pkg" == "python" ]; then
      apk add -q python2
    else
      apk add -q $required_pkg
    fi
    command -v gettext > /dev/null || {
      apk add -q gettext-dev
    }
  else
    echo_red "$(gettext 'Please install it first') $required_pkg"
    exit 1
  fi
}

function prepare_online_install_required_pkg() {
  for i in curl wget zip python; do
    command -v $i >/dev/null || install_required_pkg $i
  done
}

function prepare_set_redhat_firewalld() {
  if command -v firewall-cmd > /dev/null; then
    firewall-cmd --state > /dev/null 2>&1
    if [[ "$?" == "0" ]]; then
      docker_subnet=$(get_config DOCKER_SUBNET)
      if [[ ! "$(firewall-cmd --list-rich-rule | grep ${docker_subnet})" ]]; then
        firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=${docker_subnet} accept"
        flag=1
      fi
      if command -v dnf > /dev/null; then
        if [[ ! "$(firewall-cmd --list-all | grep 'masquerade: yes')" ]]; then
          firewall-cmd --permanent --add-masquerade
          flag=1
        fi
      fi
      if [[ "$flag" ]]; then
          firewall-cmd --reload
      fi
    fi
  fi
}

function prepare_config() {
  cd "${PROJECT_DIR}" || exit

  echo_yellow "1. $(gettext 'Check Configuration File')"
  echo "$(gettext 'Path to Configuration file'): ${CONFIG_DIR}"
  if [[ ! -d ${CONFIG_DIR} ]]; then
    mkdir -p ${CONFIG_DIR}
    cp config-example.txt "${CONFIG_FILE}"
  fi
  if [[ ! -f ${CONFIG_FILE} ]]; then
    cp config-example.txt "${CONFIG_FILE}"
  else
    echo -e "${CONFIG_FILE}  [\033[32m √ \033[0m]"
  fi
  if [[ ! -f .env ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi
  if [[ ! -f "./compose/.env" ]]; then
    ln -s "${CONFIG_FILE}" ./compose/.env
  fi
  configs=("core" "koko" "mysql" "mariadb" "redis")
  for d in "${configs[@]}"; do
    for f in $(ls ${PROJECT_DIR}/config_init/${d}); do
      if [[ ! -f "${CONFIG_DIR}/${d}/${f}" ]]; then
        \cp -rf "${PROJECT_DIR}/config_init/${d}" "${CONFIG_DIR}"
      else
        echo -e "${CONFIG_DIR}/${d}/${f}  [\033[32m √ \033[0m]"
      fi
    done
  done
  echo_done

  echo_yellow "\n2. $(gettext 'Configure Nginx')"
  echo "$(gettext 'configuration file'): ${nginx_dir}"

  nginx_dir="${CONFIG_DIR}/nginx"
  nginx_cert_dir="${CONFIG_DIR}/nginx/cert"

  if [[ ! -d ${nginx_dir} ]]; then
    mkdir -p "${nginx_dir}"
    \cp -rf "${PROJECT_DIR}/config_init/nginx" "${CONFIG_DIR}"
  fi

  for f in $(ls ${PROJECT_DIR}/config_init/nginx | grep -v cert); do
    if [[ ! -f "${nginx_dir}/${f}" ]]; then
      \cp -f "${PROJECT_DIR}/config_init/nginx/${f}" "${nginx_dir}"
    else
      echo -e "${nginx_dir}/${f}  [\033[32m √ \033[0m]"
    fi
  done

  if [[ ! -d ${nginx_cert_dir} ]]; then
    mkdir -p "${nginx_cert_dir}"
    \cp -rf "${PROJECT_DIR}/config_init/nginx/cert" "${CONFIG_DIR}/nginx"
  fi

  for f in $(ls ${PROJECT_DIR}/config_init/nginx/cert); do
    if [[ ! -f "${nginx_cert_dir}/${f}" ]]; then
      \cp -f "${PROJECT_DIR}"/config_init/nginx/cert/${f} "${nginx_cert_dir}"
    else
      echo -e "${nginx_cert_dir}/${f}  [\033[32m √ \033[0m]"
    fi
  done
  echo_done

  backup_dir="${CONFIG_DIR}/backup"
  mkdir -p "${backup_dir}"
  now=$(date +'%Y-%m-%d_%H-%M-%S')
  backup_config_file="${backup_dir}/config.txt.${now}"
  echo_yellow "\n3. $(gettext 'Backup Configuration File')"
  cp "${CONFIG_FILE}" "${backup_config_file}"
  echo "$(gettext 'Back up to') ${backup_config_file}"
  echo_done
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

  echo -e "\t\t\t\t\t\t\t\t   Version: \033[33m $VERSION \033[0m \n"
}

function get_latest_version() {
  curl -s 'https://api.github.com/repos/jumpserver/jumpserver/releases/latest' |
    grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' |
    sed 's/\"//g;s/,//g;s/ //g'
}

function image_has_prefix() {
  if [[ $1 =~ registry.* ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function perform_db_migrations() {
  volume_dir=$(get_config VOLUME_DIR)
  docker run -i --rm --network=jms_net \
    --env-file=/opt/jumpserver/config/config.txt \
    -v ${volume_dir}/core/data:/opt/jumpserver/data \
    jumpserver/core:"${VERSION}" upgrade_db
}

function check_ipv6_iptables_if_need() {
  # 检查 IPv6
  use_ipv6=$(get_config USE_IPV6)
  subnet_ipv6=$(get_config DOCKER_SUBNET_IPV6)
  if [[ "${use_ipv6}" == "1" ]]; then
    if [[ ! "$(ip6tables -t nat -L | grep "${subnet_ipv6}")" ]]; then
      ip6tables -t nat -A POSTROUTING -s "${subnet_ipv6}" -j MASQUERADE
    fi
  fi
}

function set_current_version(){
  current_version=$(get_config CURRENT_VERSION)
  if [ "${current_version}" != "${VERSION}" ]; then
    set_config CURRENT_VERSION "${VERSION}"
  fi
}
