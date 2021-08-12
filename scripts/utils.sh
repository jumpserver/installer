#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

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
  if [[ "${#uuid}" == "${len}" ]]; then
    echo "${uuid}"
  else
    head -c100 < /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c ${len}; echo
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
  default=${2-''}
  value=$(grep "^${key}=" "${CONFIG_FILE}" | awk -F= '{ print $2 }')
  if [[ -z "$value" ]];then
    value="$default"
  fi
  echo "${value}"
}

function get_env_value() {
  key=$1
  default=${2-''}
  value=$(env | grep "$key=" | awk -F= '{ print $2 }')

  echo "${value}"
}

function get_config_or_env() {
  key=$1
  value=''
  default=${2-''}
  if [[ -f "${CONFIG_FILE}" ]];then
    value=$(get_config "$key")
  fi

  if [[ -z "$value" ]];then
    value=$(get_env_value "$key")
  fi

  if [[ -z "$value" ]];then
    value="$default"
  fi
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

  mysql_images=$(get_mysql_images)
  docker run -i --rm "${mysql_images}" mysql -h"${host}" -P"${port}" -u"${user}" -p"${password}" "${db}" -e "${command}" 2>/dev/null
}

function test_redis_connect() {
  host=$1
  port=$2
  password=$3
  docker run -i --rm jumpserver/redis:6-alpine redis-cli -h "${host}" -p "${port}" -a "${password}" info | grep "redis_version" 2>/dev/null
}

function get_mysql_images() {
  if [[ "$(uname -m)" == "aarch64" ]]; then
    mysql_images=jumpserver/mariadb:10
  else
    mysql_images=jumpserver/mysql:5
  fi
  echo "${mysql_images}"
}

function get_images() {
  USE_XPACK=$(get_config_or_env USE_XPACK)
  scope="public"
  if [[ "$USE_XPACK" == "1" ]];then
    scope="all"
  fi

  mysql_images=$(get_mysql_images)

  images=(
    "jumpserver/nginx:alpine2"
    "jumpserver/redis:6-alpine"
    "${mysql_images}"
    "jumpserver/web:${VERSION}"
    "jumpserver/core:${VERSION}"
    "jumpserver/koko:${VERSION}"
    "jumpserver/lion:${VERSION}"
  )
  for image in "${images[@]}"; do
    echo "${image}"
  done
  if [[ "${scope}" == "all" ]]; then
    echo "registry.fit2cloud.com/jumpserver/omnidb:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/xrdp:${VERSION}"
  fi
}

function read_from_input() {
  var=$1
  msg=$2
  choices=$3
  default=$4
  if [[ -n "${choices}" ]]; then
    msg="${msg} (${choices}) "
  fi
  if [[ -z "${default}" ]]; then
    msg="${msg} ($(gettext 'no default'))"
  else
    msg="${msg} ($(gettext 'default') ${default})"
  fi
  echo -n "${msg}: "
  read -r input
  if [[ -z "${input}" && -n "${default}" ]]; then
    export "${var}"="${default}"
  else
    export "${var}"="${input}"
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

function echo_check() {
  echo -e "$1  [\033[32m √ \033[0m]"
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
  services="core koko lion web"
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
    services+=" omnidb xrdp"
  fi
  echo "${services}"
}

function get_docker_compose_cmd_line() {
  ignore_db="$1"
  cmd="docker-compose -f ./compose/docker-compose-app.yml"
  use_ipv6=$(get_config USE_IPV6)
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd="${cmd} -f ./compose/docker-compose-network.yml"
  else
    cmd="${cmd} -f ./compose/docker-compose-network_ipv6.yml"
  fi
  services=$(get_docker_compose_services "$ignore_db")
  if [[ "${services}" =~ celery ]]; then
    cmd="${cmd} -f ./compose/docker-compose-task.yml"
  fi
  if [[ "${services}" =~ mysql ]]; then
    if [[ "$(uname -m)" == "aarch64" ]]; then
      cmd="${cmd} -f ./compose/docker-compose-mariadb.yml"
    else
      cmd="${cmd} -f ./compose/docker-compose-mysql.yml"
    fi
  fi
  if [[ "${services}" =~ redis ]]; then
    cmd="${cmd} -f ./compose/docker-compose-redis.yml"
  fi
  if [[ "${services}" =~ lb ]]; then
    cmd="${cmd} -f ./compose/docker-compose-lb.yml"
  else
    cmd="${cmd} -f ./compose/docker-compose-web-external.yml"
  fi
  use_xpack=$(get_config USE_XPACK)
  if [[ "${use_xpack}" == '1' ]]; then
      cmd="${cmd} -f ./compose/docker-compose-xpack.yml"
  fi
  echo "${cmd}"
}

function install_required_pkg() {
  required_pkg=$1
  if command -v dnf >/dev/null; then
    if [ "$required_pkg" == "python" ]; then
      dnf -q -y install python2
    else
      dnf -q -y install "$required_pkg"
    fi
  elif command -v yum >/dev/null; then
    yum -q -y install "$required_pkg"
  elif command -v apt >/dev/null; then
    apt-get -qq -y install "$required_pkg"
  elif command -v zypper >/dev/null; then
    zypper -q -n install "$required_pkg"
  elif command -v apk >/dev/null; then
    if [ "$required_pkg" == "python" ]; then
      apk add -q python2
    else
      apk add -q "$required_pkg"
    fi
    command -v gettext >/dev/null || {
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
  if command -v firewall-cmd >/dev/null; then
    if firewall-cmd --state >/dev/null 2>&1; then
      docker_subnet=$(get_config DOCKER_SUBNET)
      if ! firewall-cmd --list-rich-rule | grep "${docker_subnet}" >/dev/null; then
        firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=${docker_subnet} accept" >/dev/null
        flag=1
      fi
      if command -v dnf >/dev/null; then
        if ! firewall-cmd --list-all | grep 'masquerade: yes' >/dev/null; then
          firewall-cmd --permanent --add-masquerade >/dev/null
          flag=1
        fi
      fi
      if [[ "$flag" ]]; then
        firewall-cmd --reload >/dev/null
        unset flag
      fi
    fi
  fi
}

function prepare_config() {
  cd "${PROJECT_DIR}" || exit 1
  if [[ "$OS" != 'Darwin' ]];then
    echo -e "#!/usr/bin/env bash\n#" > /usr/bin/jmsctl
    echo -e "cd ${PROJECT_DIR}" >> /usr/bin/jmsctl
    echo -e './jmsctl.sh $@' >> /usr/bin/jmsctl
    chmod 755 /usr/bin/jmsctl
  fi

  echo_yellow "1. $(gettext 'Check Configuration File')"
  echo "$(gettext 'Path to Configuration file'): ${CONFIG_DIR}"
  if [[ ! -d ${CONFIG_DIR} ]]; then
    mkdir -p "${CONFIG_DIR}"
    cp config-example.txt "${CONFIG_FILE}"
  fi
  if [[ ! -f ${CONFIG_FILE} ]]; then
    cp config-example.txt "${CONFIG_FILE}"
  else
    echo_check "${CONFIG_FILE}"
  fi
  if [[ ! -f .env ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi
  if [[ ! -f "./compose/.env" ]]; then
    ln -s "${CONFIG_FILE}" ./compose/.env
  fi

  for d in "${PROJECT_DIR}"/config_init/*; do
    if [[ -d "${PROJECT_DIR}/config_init/${d}" ]]; then
      for f in "${PROJECT_DIR}"/config_init/"${d}"/*; do
        if [[ -f "${PROJECT_DIR}/config_init/${d}/${f}" ]]; then
          if [[ ! -f "${CONFIG_DIR}/${d}/${f}" ]]; then
            \cp -rf "${PROJECT_DIR}/config_init/${d}" "${CONFIG_DIR}"
          else
            echo_check "${CONFIG_DIR}/${d}/${f}"
          fi
        fi
      done
    fi
  done

  nginx_cert_dir="${CONFIG_DIR}/nginx/cert"
  if [[ ! -d ${nginx_cert_dir} ]]; then
    mkdir -p "${nginx_cert_dir}"
    \cp -rf "${PROJECT_DIR}/config_init/nginx/cert" "${CONFIG_DIR}/nginx"
  fi

  for f in "${PROJECT_DIR}"/config_init/nginx/cert/*; do
    if [[ -f "${PROJECT_DIR}/config_init/nginx/cert/${f}" ]]; then
      if [[ ! -f "${nginx_cert_dir}/${f}" ]]; then
        \cp -f "${PROJECT_DIR}/config_init/nginx/cert/${f}" "${nginx_cert_dir}"
      else
        echo_check "${nginx_cert_dir}/${f} "
      fi
    fi
  done
  find "${CONFIG_DIR}" -type d -exec chmod 755 {} \;
  find "${CONFIG_DIR}" -type f -exec chmod 644 {} \;
  echo_done

  if [[ "$(uname -m)" == "aarch64" ]]; then
    sed -i "s/# ignore-warnings ARM64-COW-BUG/ignore-warnings ARM64-COW-BUG/g" "${CONFIG_DIR}/redis/redis.conf"
  fi

  backup_dir="${CONFIG_DIR}/backup"
  mkdir -p "${backup_dir}"
  now=$(date +'%Y-%m-%d_%H-%M-%S')
  backup_config_file="${backup_dir}/config.txt.${now}"
  echo_yellow "\n2. $(gettext 'Backup Configuration File')"
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

function get_db_migrate_compose_cmd() {
  use_external_mysql=$(get_config USE_EXTERNAL_MYSQL)
  use_external_redis=$(get_config USE_EXTERNAL_REDIS)
  use_ipv6=$(get_config USE_IPV6)

  docker rm -f jms_init_db &> /dev/null || true
  cmd="docker-compose -f ./compose/docker-compose-init-db.yml"
  if [[ "${use_external_mysql}" == "0" ]]; then
    if [[ "$(uname -m)" == "aarch64" ]]; then
      cmd="${cmd} -f ./compose/docker-compose-mariadb.yml"
    else
      cmd="${cmd} -f ./compose/docker-compose-mysql.yml"
    fi
  fi

  if [[ "${use_external_redis}" == "0" ]]; then
    cmd="${cmd} -f ./compose/docker-compose-redis.yml"
  fi

  if [[ "${use_ipv6}" != "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-network.yml"
  else
    cmd="${cmd} -f compose/docker-compose-network_ipv6.yml"
  fi
  echo "$cmd"
}

function get_jms_net_compose_cmd() {
  cmd="docker-compose -f ./compose/docker-compose-init-db.yml"
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-network.yml"
  else
    cmd="${cmd} -f compose/docker-compose-network_ipv6.yml"
  fi
  echo "$cmd"
}

function create_jms_network() {
  cmd=$(get_jms_net_compose_cmd)
  ${cmd} up -d
}

function down_jms_network() {
  cmd=$(get_jms_net_compose_cmd)
  ${cmd} down
}

function perform_db_migrations() {
  cmd=$(get_db_migrate_compose_cmd)
  ${cmd} up -d

  docker exec -it jms_init_db bash -c './jms upgrade_db'
  ret=$?

  ${cmd} down
  if [[ "$ret" == "0" ]]; then
    echo "完成数据库升级，清理容器"
  else
    echo "初始化数据失败"
    exit 1
  fi
}

function check_ipv6_iptables_if_need() {
  # 检查 IPv6
  use_ipv6=$(get_config USE_IPV6)
  subnet_ipv6=$(get_config DOCKER_SUBNET_IPV6)
  if [[ "${use_ipv6}" == "1" ]]; then
    if ! ip6tables -t nat -L | grep "${subnet_ipv6}" >/dev/null; then
      ip6tables -t nat -A POSTROUTING -s "${subnet_ipv6}" -j MASQUERADE
    fi
  fi
}

function set_current_version() {
  current_version=$(get_config CURRENT_VERSION)
  if [ "${current_version}" != "${VERSION}" ]; then
    set_config CURRENT_VERSION "${VERSION}"
  fi
}

function get_current_version() {
  current_version=$(get_config CURRENT_VERSION)
  if [ -z "${current_version}" ]; then
    current_version="${VERSION}"
  fi
  echo "${current_version}"
}

function pull_image() {
  image=$1
  DOCKER_IMAGE_PREFIX=$(get_config_or_env 'DOCKER_IMAGE_PREFIX')
  IMAGE_PULL_POLICY=${IMAGE_PULL_POLICY-"Always"}

  if docker image inspect -f '{{ .Id }}' "$image" &> /dev/null; then
    exits=0
  else
    exits=1
  fi

  if [[ "$exits" == "0" && "$IMAGE_PULL_POLICY" != "Always" ]];then
    echo "Image exist, pass"
    return
  fi

  if [[ -n "${DOCKER_IMAGE_PREFIX}" && $(image_has_prefix "${image}") == "0" ]]; then
    docker pull "${DOCKER_IMAGE_PREFIX}/${image}"
    docker tag "${DOCKER_IMAGE_PREFIX}/${image}" "${image}"
    docker rmi -f "${DOCKER_IMAGE_PREFIX}/${image}"
  else
    docker pull "${image}"
  fi
  echo ""
}

function pull_images() {
  images_to=$(get_images)

  for image in ${images_to}; do
    echo "[${image}]"
    pull_image "$image"
  done
}
