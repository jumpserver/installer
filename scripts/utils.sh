#!/usr/bin/env bash
#

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/const.sh"

function check_root() {
  [[ "$(id -u)" == 0 ]]
}

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
    len=24
  fi
  uuid=""
  if check_root && command -v dmidecode &>/dev/null; then
    if [[ ${len} -gt 24 ]]; then
      uuid=$(dmidecode -s system-uuid | sha256sum | awk '{print $1}' | head -c ${len})
    fi
  fi
  if [[ "${#uuid}" == "${len}" ]]; then
    echo "${uuid}"
  else
    head -c200 < /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c ${len}; echo
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
  value=$(grep "^${key}=" "${CONFIG_FILE}" | awk -F= '{ print $2 }' | awk -F' ' '{ print $1 }' | tail -1)
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

function disable_config() {
  key=$1

  has=$(has_config "${key}")
  if [[ ${has} == "1" ]]; then
    sed -i "s,^[ \t]*${key}=.*$,# ${key}=,g" "${CONFIG_FILE}"
  fi
}

function check_volume_dir() {
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -d "${volume_dir}" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function check_db_data() {
  db_type=$1
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    return
  fi
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -d "${volume_dir}/${db_type}/data" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function get_db_info() {
  info_type=$1
  db_engine=$(get_config DB_ENGINE "mysql")
  db_host=$(get_config DB_HOST)
  check_volume_dir=$(check_volume_dir)
  if [[ "${check_volume_dir}" == "0" ]]; then
    db_engine=$(get_config DB_ENGINE "postgresql")
  fi

  mysql_data_exists="0"
  mariadb_data_exists="0"
  postgres_data_exists="0"

  case "${db_engine}" in
    "mysql")
      if [[ "${db_host}" == "mysql" ]]; then
        mysql_data_exists=$(check_db_data "mysql")
      fi
      mariadb_data_exists="1"
      ;;
    "postgresql")
      postgres_data_exists="1"
      ;;
  esac

  case "${info_type}" in
    "image")
      if [[ "${mysql_data_exists}" == "1" ]]; then
        echo "mysql:5.7-debian"
      elif [[ "${mariadb_data_exists}" == "1" ]]; then
        echo "mariadb:10.6"
      elif [[ "${postgres_data_exists}" == "1" ]]; then
        echo "postgres:16.10-bookworm"
      fi
      ;;
    "file")
      if [[ "${mysql_data_exists}" == "1" ]]; then
        echo "compose/mysql.yml"
      elif [[ "${mariadb_data_exists}" == "1" ]]; then
        echo "compose/mariadb.yml"
      elif [[ "${postgres_data_exists}" == "1" ]]; then
        echo "compose/postgres.yml"
      fi
      ;;
    *)
      exit 1 ;;
  esac
}

function get_db_images() {
  get_db_info "image"
}

function get_db_images_file() {
  get_db_info "file"
}

function get_images() {
  use_xpack=$(get_config_or_env USE_XPACK)
  db_images=$(get_db_images)
  images=(
    "redis:7.4.6-bookworm"
    "${db_images}"
  )
  for image in "${images[@]}"; do
    echo "${image}"
  done
  if [[ "$use_xpack" == "1" ]];then
    echo "registry.fit2cloud.com/jumpserver/core:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/koko:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/lion:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/chen:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/web:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/magnus:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/razor:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/video-worker:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/xrdp:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/panda:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/nec:${VERSION}"
    echo "registry.fit2cloud.com/jumpserver/facelive:${VERSION}"
  else
    echo "jumpserver/core:${VERSION}"
    echo "jumpserver/koko:${VERSION}"
    echo "jumpserver/lion:${VERSION}"
    echo "jumpserver/chen:${VERSION}"
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
  db_engine=$(get_config DB_ENGINE "mysql")
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)
  use_es=$(get_config USE_ES)
  use_minio=$(get_config USE_MINIO)
  use_loki=$(get_config USE_LOKI)

  use_xpack=$(get_config_or_env USE_XPACK)

  services="core celery koko lion chen web"

  receptor_enabled=$(get_config RECEPTOR_ENABLED)
  if [[ "${receptor_enabled}" == "1" ]]; then
    services+=" receptor"
  fi

  if [[ "${ignore_db}" != "ignore_db" ]]; then
    case "${db_engine}" in
      mysql)
        [[ "${db_host}" == "mysql" ]] && services+=" mysql"
        ;;
      postgresql)
        [[ "${db_host}" == "postgresql" ]] && services+=" postgresql"
        ;;
    esac
    [[ "${redis_host}" == "redis" ]] && services+=" redis"
  fi

  for service in core celery koko lion chen web; do
    enabled=$(get_config "${service^^}_ENABLED")
    [[ "${enabled}" == "0" ]] && services="${services//${service}/}"
  done

  [[ "${use_es}" == "1" ]] && services+=" es"
  [[ "${use_minio}" == "1" ]] && services+=" minio"
  [[ "${use_loki}" == "1" ]] && services+=" loki"

  if [[ "${use_xpack}" == "1" ]]; then
    services+=" magnus razor xrdp video panda nec facelive"
    for service in magnus razor xrdp video panda nec facelive; do
      enabled=$(get_config "${service^^}_ENABLED")
      [[ "${enabled}" == "0" ]] && services="${services//${service}/}"
    done
  fi

  echo "${services}"
}

function get_docker_compose_cmd_line() {
  ignore_db="$1"
  use_ipv6=$(get_config USE_IPV6)
  use_xpack=$(get_config_or_env USE_XPACK)
  https_port=$(get_config HTTPS_PORT)
  db_images_file=$(get_db_images_file)
  cmd="docker compose"
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd+=" -f compose/network.yml"
  else
    cmd+=" -f compose/network-v6.yml"
  fi
  services=$(get_docker_compose_services "$ignore_db")

  for service in core celery receptor koko lion chen web redis; do
    if [[ "${services}" =~ ${service} ]]; then
      cmd+=" -f compose/${service}.yml"
    fi
  done

  if [[ "${services}" =~ "mysql" || "${services}" =~ "postgresql" ]]; then
    cmd+=" -f ${db_images_file}"
  fi

  use_es=$(get_config USE_ES)
  if [[ "${use_es}" == "1" ]]; then
    cmd+=" -f compose/es.yml"
  fi

  use_minio=$(get_config USE_MINIO)
  if [[ "${use_minio}" == "1" ]]; then
    cmd+=" -f compose/minio.yml"
  fi

  if [[ -n "${https_port}" ]]; then
    cmd+=" -f compose/lb.yml"
  fi

  if [[ "${services}" =~ loki ]]; then
    cmd+=" -f compose/loki.yml"
  fi

  if [[ "${use_xpack}" == '1' ]]; then
    for service in magnus razor xrdp video panda nec facelive; do
      if [[ "${services}" =~ ${service} ]]; then
        cmd+=" -f compose/${service}.yml"
      fi
    done
  fi

  echo "${cmd}"
}

function get_video_worker_cmd_line() {
  use_xpack=$(get_config_or_env USE_XPACK)
  if [[ "${use_xpack}" != "1" ]]; then
    return
  fi
  use_ipv6=$(get_config USE_IPV6)
  cmd="docker compose"
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd+=" -f compose/network.yml"
  else
    cmd+=" -f compose/network-v6.yml"
  fi
  cmd+=" -f compose/video-worker.yml"
  echo "${cmd}"
}

function prepare_check_required_pkg() {
  for i in curl wget tar iptables gettext; do
    command -v $i &>/dev/null || {
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
  if command -v firewall-cmd&>/dev/null; then
    if firewall-cmd --state &>/dev/null; then
      docker_subnet=$(get_config DOCKER_SUBNET)
      if ! firewall-cmd --list-rich-rule | grep "${docker_subnet}"&>/dev/null; then
        firewall-cmd --zone=public --add-rich-rule="rule family=ipv4 source address=${docker_subnet} accept" >/dev/null
        firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=${docker_subnet} accept" >/dev/null
      fi
    fi
  fi
}

function prepare_config() {
  cd "${PROJECT_DIR}" || exit 1
  if check_root; then
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
  chmod 644 "${CONFIG_DIR}/mariadb/mariadb.cnf"

  if [[ "$(uname -m)" == "aarch64" ]]; then
    sed -i "s/# ignore-warnings ARM64-COW-BUG/ignore-warnings ARM64-COW-BUG/g" "${CONFIG_DIR}/redis/redis.conf"
  fi
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
  if [[ $1 =~ jumpserver.* ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function get_db_migrate_compose_cmd() {
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)
  use_ipv6=$(get_config USE_IPV6)
  use_xpack=$(get_config_or_env USE_XPACK)

  cmd="docker compose -f compose/init-db.yml"
  if [[ "${db_host}" == "mysql" ]] || [[ "${db_host}" == "postgresql" ]]; then
    db_images_file=$(get_db_images_file)
    cmd+=" -f ${db_images_file}"
  fi
  if [[ "${redis_host}" == "redis" ]]; then
    cmd+=" -f compose/redis.yml"
  fi
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd+=" -f compose/network.yml"
  else
    cmd+=" -f compose/network-v6.yml"
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
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)

  create_db_ops_env
  case "${db_host}" in
    mysql|postgresql)
      while [[ "$(docker inspect -f "{{.State.Health.Status}}" jms_${db_host})" != "healthy" ]]; do
        sleep 5s
      done
      ;;
  esac

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
  IMAGE_PULL_POLICY=$(get_config_or_env 'IMAGE_PULL_POLICY')

  if [[ "${DOCKER_IMAGE_MIRROR}" == "1" ]]; then
    DOCKER_IMAGE_PREFIX="registry.cn-beijing.aliyuncs.com/jumpservice"
  else
    DOCKER_IMAGE_PREFIX=$(get_config_or_env 'DOCKER_IMAGE_PREFIX')
  fi

  if docker image inspect -f '{{ .Id }}' "$image" &>/dev/null; then
    exists=0
  else
    exists=1
  fi

  if [[ "$exists" == "0" && "$IMAGE_PULL_POLICY" != "Always" ]]; then
    echo "[${image}] exist, pass"
    return
  fi

  pull_args=""
  case "${BUILD_ARCH}" in
    "x86_64") pull_args="--platform linux/amd64" ;;
    "aarch64") pull_args="--platform linux/arm64" ;;
    "loongarch64") pull_args="--platform linux/loong64" ;;
    "s390x") pull_args="--platform linux/s390x" ;;
  esac

  echo "[${image}] pulling"
  full_image_path="${image}"
  if [[ -n "${DOCKER_IMAGE_PREFIX}" ]]; then
    if echo "${DOCKER_IMAGE_PREFIX}" | grep -q "/";then
      app=$(echo "$image" | awk -F'/' '{ print $NF }')
      full_image_path="${DOCKER_IMAGE_PREFIX}/${app}"
    elif [[ $(image_has_prefix "${image}") != "1" ]]; then
      full_image_path="${DOCKER_IMAGE_PREFIX}/jumpserver/${image}"
    else
      full_image_path="${DOCKER_IMAGE_PREFIX}/${image}"
    fi
  fi

  if [[ "${full_image_path}" != "${image}" ]]; then
    echo "  -> [${full_image_path}]"
  fi
  docker pull ${pull_args} "${full_image_path}"
  if [[ "${full_image_path}" != "${image}" ]]; then
    docker tag "${full_image_path}" "${image}"
    docker rmi -f "${full_image_path}"
  fi
  echo ""
}

function check_images() {
  images_to=$(get_images)
  failed=0

  for image in ${images_to}; do
    if ! docker image inspect -f '{{ .Id }}' "$image" &>/dev/null; then
      pull_image "$image"
    fi
  done
  for image in ${images_to}; do
    if ! docker image inspect -f '{{ .Id }}' "$image" &>/dev/null; then
      echo_red "$(gettext 'Failed to pull image') ${image}"
      failed=1
    fi
  done

  if [ $failed -eq 1 ]; then
    exit 1
  fi
}

function pull_images() {
  images_to=$(get_images)
  pids=()

  trap 'kill ${pids[*]}' SIGINT SIGTERM

  for image in ${images_to}; do
    pull_image "$image" &
    pids+=($!)
  done
  wait ${pids[*]}

  trap - SIGINT SIGTERM

  check_images
}

function installation_log() {
  if [ -d "${BASE_DIR}/images" ]; then
    return
  fi
  product=js
  install_type=$1
  version=$(get_current_version)
  url="https://community.fit2cloud.com/installation-analytics?product=${product}&type=${install_type}&version=${version}"
  curl --connect-timeout 5 -m 10 -k $url &>/dev/null
}

function get_host_ip() {
  local default_ip="127.0.0.1"
  host=$(command -v hostname &>/dev/null && hostname -I | cut -d ' ' -f1)
  if [ ! "${host}" ]; then
      host=$(command -v ip &>/dev/null && ip addr | grep 'inet ' | grep -Ev '(127.0.0.1|inet6|docker)' | awk '{print $2}' | head -n 1 | cut -d / -f1)
  fi
  if [[ ${host} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "${host}"
  else
      echo "${default_ip}"
  fi
}
