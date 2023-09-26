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
  if grep "^[ \t]*${key}=" "${CONFIG_FILE}" &>/dev/null; then
    echo "1"
  else
    echo "0"
  fi
}

function get_config() {
  key=$1
  default=${2-''}
  value=$(grep "^${key}=" "${CONFIG_FILE}" | awk -F= '{ print $2 }' | awk -F' ' '{ print $1 }')
  if [[ -z "$value" ]];then
    value="$default"
  fi
  echo "${value}"
}

function get_env_value() {
  key=$1
  default=${2-''}
  value="${!key}"
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

  sed -i "s,^[ \t]*${key}=.*$,${key}=${value},g" "${CONFIG_FILE}"
}

function check_mysql_data() {
   if [[ ! -f "${CONFIG_FILE}" ]]; then
     return
   fi
   volume_dir=$(get_config VOLUME_DIR)
   db_name=$(get_config DB_NAME)
   if [[ -d "${volume_dir}/mysql/data/${db_name}" ]]; then
     echo "1"
   fi
}

function get_mysql_images() {
  mysql_data_exists=$(check_mysql_data)
  if [[ "${mysql_data_exists}" == "1" ]]; then
    mysql_images=jumpserver/mysql:5.7
  else
    mysql_images=jumpserver/mariadb:10.6
  fi
  echo "${mysql_images}"
}

function get_mysql_images_file() {
  mysql_data_exists=$(check_mysql_data)
  if [[ "${mysql_data_exists}" == "1" ]]; then
    mysql_images_file=compose/docker-compose-mysql.yml
  else
    mysql_images_file=compose/docker-compose-mariadb.yml
  fi
  echo "${mysql_images_file}"
}

function get_images() {
  use_xpack=$(get_config_or_env USE_XPACK)
  mysql_images=$(get_mysql_images)
  images=(
    "jumpserver/redis:6.2"
    "${mysql_images}"
  )
  for image in "${images[@]}"; do
    echo "${image}"
  done
  if [[ "$use_xpack" == "1" ]];then
    echo "registry.fit2cloud.com/jumpserver/core:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/koko:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/lion:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/magnus:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/chen:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/kael:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/razor:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/web:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/video-worker:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/xrdp:${VERSION}"
  else
    echo "jumpserver/core:${VERSION}"
    echo "jumpserver/koko:${VERSION}"
    echo "jumpserver/lion:${VERSION}"
    echo "jumpserver/magnus:${VERSION}"
    echo "jumpserver/chen:${VERSION}"
    echo "jumpserver/kael:${VERSION}"
    echo "jumpserver/web:${VERSION}"
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
  echo -e "$1 \t [\033[32m √ \033[0m]"
}

function echo_warn() {
  echo -e "[\033[33m WARNING \033[0m] $1"
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
  core_enabled=$(get_config CORE_ENABLED)
  celery_enabled=$(get_config CELERY_ENABLED)
  koko_enabled=$(get_config KOKO_ENABLED)
  lion_enabled=$(get_config LION_ENABLED)
  magnus_enabled=$(get_config MAGNUS_ENABLED)
  chen_enabled=$(get_config CHEN_ENABLED)
  kael_enabled=$(get_config KAEL_ENABLED)
  web_enabled=$(get_config WEB_ENABLED)
  services="core celery koko lion magnus chen kael web"
  if [[ "${core_enabled}" == "0" ]]; then
    services="${services//core/}"
  fi
  if [[ "${celery_enabled}" == "0" ]]; then
    services="${services//celery/}"
  fi
  if [[ "${koko_enabled}" == "0" ]]; then
    services="${services//koko/}"
  fi
  if [[ "${lion_enabled}" == "0" ]]; then
    services="${services//lion/}"
  fi
  if [[ "${magnus_enabled}" == "0" ]]; then
    services="${services//magnus/}"
  fi
  if [[ "${chen_enabled}" == "0" ]]; then
    services="${services//chen/}"
  fi
  if [[ "${kael_enabled}" == "0" ]]; then
    services="${services//kael/}"
  fi
  if [[ "${web_enabled}" == "0" ]]; then
    services="${services//web/}"
  fi
  mysql_host=$(get_config DB_HOST)
  if [[ "${mysql_host}" == "mysql" && "${ignore_db}" != "ignore_db" ]]; then
    services+=" mysql"
  fi
  redis_host=$(get_config REDIS_HOST)
  if [[ "${redis_host}" == "redis" && "${ignore_db}" != "ignore_db" ]]; then
    services+=" redis"
  fi
  use_es=$(get_config USE_ES)
  if [[ "${use_es}" == "1" ]]; then
    services+=" es"
  fi
  use_minio=$(get_config USE_MINIO)
  if [[ "${use_minio}" == "1" ]]; then
    services+=" minio"
  fi
  use_xpack=$(get_config_or_env USE_XPACK)
  if [[ "${use_xpack}" == "1" ]]; then
    services+=" razor xrdp video"
    razor_enabled=$(get_config RAZOR_ENABLED)
    xrdp_enabled=$(get_config XRDP_ENABLED)
    video_enabled=$(get_config VIDEO_ENABLED)
    if [[ "${razor_enabled}" == "0" ]]; then
      services="${services//razor/}"
    fi
    if [[ "${xrdp_enabled}" == "0" ]]; then
      services="${services//xrdp/}"
    fi
    if [[ "${video_enabled}" == "0" ]]; then
      services="${services//video/}"
    fi
  fi
  echo "${services}"
}

function get_docker_compose_cmd_line() {
  ignore_db="$1"
  cmd="docker-compose"
  use_ipv6=$(get_config USE_IPV6)
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-network.yml"
  else
    cmd="${cmd} -f compose/docker-compose-network_v6.yml"
  fi
  services=$(get_docker_compose_services "$ignore_db")
  if [[ "${services}" =~ core ]]; then
    cmd="${cmd} -f compose/docker-compose-core.yml"
  fi
  if [[ "${services}" =~ celery ]]; then
    cmd="${cmd} -f compose/docker-compose-celery.yml"
  fi
  if [[ "${services}" =~ koko ]]; then
    cmd="${cmd} -f compose/docker-compose-koko.yml"
  fi
  if [[ "${services}" =~ lion ]]; then
    cmd="${cmd} -f compose/docker-compose-lion.yml"
  fi
  if [[ "${services}" =~ magnus ]]; then
    cmd="${cmd} -f compose/docker-compose-magnus.yml"
  fi
  if [[ "${services}" =~ chen ]]; then
    cmd="${cmd} -f compose/docker-compose-chen.yml"
  fi
  if [[ "${services}" =~ kael ]]; then
    cmd="${cmd} -f compose/docker-compose-kael.yml"
  fi
  if [[ "${services}" =~ web ]]; then
    cmd="${cmd} -f compose/docker-compose-web.yml"
  fi
  if [[ "${services}" =~ mysql ]]; then
    mysql_images_file=$(get_mysql_images_file)
    cmd="${cmd} -f ${mysql_images_file}"
  fi
  if [[ "${services}" =~ redis ]]; then
    cmd="${cmd} -f compose/docker-compose-redis.yml"
  fi
  if [[ "${services}" =~ es ]]; then
    cmd="${cmd} -f compose/docker-compose-es.yml"
  fi
  if [[ "${services}" =~ minio ]]; then
    cmd="${cmd} -f compose/docker-compose-minio.yml"
  fi
  use_lb=$(get_config USE_LB)
  https_port=$(get_config HTTPS_PORT)
  if [[ -n "${https_port}" && "${use_lb}" != "0" ]]; then
    cmd="${cmd} -f compose/docker-compose-lb.yml"
  fi
  use_xpack=$(get_config_or_env USE_XPACK)
  if [[ "${use_xpack}" == '1' ]]; then
    cmd="${cmd} -f compose/docker-compose-magnus-xpack.yml"
    if [[ "${services}" =~ razor ]]; then
      cmd="${cmd} -f compose/docker-compose-razor.yml"
    fi
    if [[ "${services}" =~ xrdp ]]; then
      cmd="${cmd} -f compose/docker-compose-xrdp.yml"
    fi
    if [[ "${services}" =~ video ]]; then
      cmd="${cmd} -f compose/docker-compose-video.yml"
    fi
  fi
  echo "${cmd}"
}

function get_video_worker_cmd_line() {
  use_xpack=$(get_config_or_env USE_XPACK)
  if [[ "${use_xpack}" != "1" ]]; then
    return
  fi
  use_ipv6=$(get_config USE_IPV6)
  cmd="docker-compose -f compose/docker-compose-network.yml"
  if [[ "${use_ipv6}" == "1" ]]; then
    cmd="docker-compose -f compose/docker-compose-network_v6.yml"
  fi
  cmd="${cmd} -f compose/docker-compose-video-worker.yml"
  echo "${cmd}"
}

function prepare_check_required_pkg() {
  for i in curl wget tar iptables gettext; do
    command -v $i >/dev/null || {
        echo_red "$i: $(gettext 'command not found, Please install it first') $i"
        flag=1
    }
  done
  if [[ -n "$flag" ]]; then
    unset flag
    echo
    exit 1
  fi
}

function prepare_set_redhat_firewalld() {
  if command -v firewall-cmd >/dev/null; then
    if firewall-cmd --state >/dev/null 2>&1; then
      docker_subnet=$(get_config DOCKER_SUBNET)
      if ! firewall-cmd --list-rich-rule | grep "${docker_subnet}" >/dev/null; then
        firewall-cmd --zone=public --add-rich-rule="rule family=ipv4 source address=${docker_subnet} accept" >/dev/null
        firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=${docker_subnet} accept" >/dev/null
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
  if [[ ! -f ".env" ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi
  if [[ ! -f "./compose/.env" ]]; then
    ln -s "${CONFIG_FILE}" ./compose/.env
  fi
  if [[ "$(uname -m)" == "loongarch64" ]]; then
    if ! grep -q "^SECURITY_LOGIN_CAPTCHA_ENABLED" "${CONFIG_FILE}"; then
      echo "SECURITY_LOGIN_CAPTCHA_ENABLED=False" >> "${CONFIG_FILE}"
    fi
  fi

  # shellcheck disable=SC2045
  for d in $(ls "${PROJECT_DIR}/config_init"); do
    if [[ -d "${PROJECT_DIR}/config_init/${d}" ]]; then
      for f in $(ls "${PROJECT_DIR}/config_init/${d}"); do
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

  # shellcheck disable=SC2045
  for f in $(ls "${PROJECT_DIR}/config_init/nginx/cert"); do
    if [[ -f "${PROJECT_DIR}/config_init/nginx/cert/${f}" ]]; then
      if [[ ! -f "${nginx_cert_dir}/${f}" ]]; then
        \cp -f "${PROJECT_DIR}/config_init/nginx/cert/${f}" "${nginx_cert_dir}"
      else
        echo_check "${nginx_cert_dir}/${f} "
      fi
    fi
  done
  chmod 700 "${CONFIG_DIR}/../"
  find "${CONFIG_DIR}" -type d -exec chmod 700 {} \;
  find "${CONFIG_DIR}" -type f -exec chmod 600 {} \;
  chmod 644 "${CONFIG_DIR}/redis/redis.conf"

  if [[ "$(uname -m)" == "aarch64" ]]; then
    sed -i "s/# ignore-warnings ARM64-COW-BUG/ignore-warnings ARM64-COW-BUG/g" "${CONFIG_DIR}/redis/redis.conf"
  fi
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
  if [[ $1 =~ registry.fit2cloud.com.* ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function get_db_migrate_compose_cmd() {
  mysql_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)
  use_ipv6=$(get_config USE_IPV6)

  cmd="docker-compose -f compose/docker-compose-init-db.yml"
  if [[ "${mysql_host}" == "mysql" ]]; then
    mysql_images_file=$(get_mysql_images_file)
    cmd="${cmd} -f ${mysql_images_file}"
  fi
  if [[ "${redis_host}" == "redis" ]]; then
    cmd="${cmd} -f compose/docker-compose-redis.yml"
  fi
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-network.yml"
  else
    cmd="${cmd} -f compose/docker-compose-network_v6.yml"
  fi
  echo "$cmd"
}

function create_db_ops_env() {
  cmd=$(get_db_migrate_compose_cmd)
  ${cmd} up -d || {
    exit 1
  }
}

function down_db_ops_env() {
  docker stop jms_core &>/dev/null
  docker rm jms_core &>/dev/null
}

function perform_db_migrations() {
  mysql_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)

  create_db_ops_env
  if [[ "${mysql_host}" == "mysql" ]]; then
    while [[ "$(docker inspect -f "{{.State.Health.Status}}" jms_mysql)" != "healthy" ]]; do
      sleep 5s
    done
  fi
  if [[ "${redis_host}" == "redis" ]]; then
    while [[ "$(docker inspect -f "{{.State.Health.Status}}" jms_redis)" != "healthy" ]]; do
      sleep 5s
    done
  fi

  docker exec -i jms_core bash -c './jms upgrade_db' || {
    log_error "$(gettext 'Failed to change the table structure')!"
    exit 1
  }
}

function set_current_version() {
  current_version=$(get_config CURRENT_VERSION)
  if [ "${current_version}" != "${VERSION}" ]; then
    set_config CURRENT_VERSION "${VERSION}"
  fi
}

function get_current_version() {
  current_version=$(get_config CURRENT_VERSION "${VERSION}")
  echo "${current_version}"
}

function pull_image() {
  image=$1
  DOCKER_IMAGE_MIRROR=$(get_config_or_env 'DOCKER_IMAGE_MIRROR')
  if [[ "${DOCKER_IMAGE_MIRROR}" == "1" ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
      DOCKER_IMAGE_PREFIX="swr.cn-north-1.myhuaweicloud.com"
    fi
    if [[ "$(uname -m)" == "aarch64" ]]; then
      DOCKER_IMAGE_PREFIX="swr.cn-north-4.myhuaweicloud.com"
    fi
    if [[ "$(uname -m)" == "loongarch64" ]]; then
      DOCKER_IMAGE_PREFIX="swr.cn-southwest-2.myhuaweicloud.com"
    fi
  else
    DOCKER_IMAGE_PREFIX=$(get_config_or_env 'DOCKER_IMAGE_PREFIX')
  fi

  IMAGE_PULL_POLICY=$(get_config_or_env 'IMAGE_PULL_POLICY')

  if docker image inspect -f '{{ .Id }}' "$image" &> /dev/null; then
    exits=0
  else
    exits=1
  fi

  if [[ "$exits" == "0" && "$IMAGE_PULL_POLICY" != "Always" ]]; then
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
  DOCKER_IMAGE_MIRROR=$(get_config_or_env 'DOCKER_IMAGE_MIRROR')
  DOCKER_IMAGE_PREFIX=$(get_config_or_env 'DOCKER_IMAGE_PREFIX')
  if [[ -z "${DOCKER_IMAGE_PREFIX}" ]] && [[ -z "${DOCKER_IMAGE_MIRROR}" ]]; then
    return
  fi
  images_to=$(get_images)

  for image in ${images_to}; do
    echo "[${image}]"
    pull_image "$image"
  done
}

function installation_log() {
  if [ -d "${BASE_DIR}/images" ]; then
    return
  fi
  product=js
  install_type=$1
  version=$(get_current_version)
  url="https://community.fit2cloud.com/installation-analytics?product=${product}&type=${install_type}&version=${version}"
  curl --connect-timeout 5 -m 10 -k $url > /dev/null 2>&1
}

function get_host_ip() {
  host=$(command -v ip &> /dev/null && ip addr | grep 'state UP' -A2 | grep inet | grep -Ev '(127.0.0.1|inet6|docker)' | awk '{print $2}' | tr -d "addr:" | head -n 1 | cut -d / -f1)
  if [ ! "${host}" ]; then
      host=$(hostname -I | cut -d ' ' -f1)
  fi
  if [[ ${host} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "${host}"
  fi
}