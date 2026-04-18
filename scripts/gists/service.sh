
common_services=(core celery koko lion chen web)
xpack_services=(magnus razor xrdp video panda nec facelive)


function get_enabled_services() {
  enabled_services=()

  use_xpack=$(get_config_or_env USE_XPACK)
  services=("${common_services[@]}")
  if [[ "${use_xpack}" == "1" ]]; then
    services+=("${xpack_services[@]}")
  fi

  for service in "${services[@]}"; do
    key=$(echo "$service" | tr '[:lower:]' '[:upper:]')
    key="${key}_ENABLED"
    key=$(echo "$key" | sed 's/-/_/g')
    if [[ "${service}" == "video-worker" ]]; then
      key="VIDEO_ENABLED"
    fi
    if [[ "$(get_config_or_env "${key}")" != "0" ]]; then
      enabled_services+=("${service}")
    fi
  done
 
  echo "${enabled_services[@]}"
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

  postgresql_expose_port=$(get_config POSTGRESQL_EXPOSE_PORT)
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
        if [[ -n "${postgresql_expose_port}" ]]; then
          echo "compose/postgresql.yml -f compose/postgresql.port.yml"
        else
          echo "compose/postgresql.yml"
        fi
      fi
      ;;
    *)
      exit 1 ;;
  esac
}


function get_docker_compose_services() {
  ignore_db="$1"
  db_engine=$(get_config DB_ENGINE "mysql")
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)
  use_es=$(get_config USE_ES)
  use_minio=$(get_config USE_MINIO)
  use_loki=$(get_config USE_LOKI)
  ha_mode=$(get_config HA_MODE)
  use_xpack=$(get_config_or_env USE_XPACK)
  services=$(get_enabled_services)

  if [[ "${ignore_db}" != "ignore_db" ]]; then
    info=(get_db_info)
    case "${db_engine}" in
      mysql)
        [[ "${db_host}" == "mysql" || "${ha_mode}" == "1" ]] && services+=" mysql"
        ;;
      postgresql)
        [[ "${db_host}" == "postgresql" || "${ha_mode}" == "1" ]] && services+=" postgresql"
        ;;
    esac
    [[ "${redis_host}" == "redis" || "${ha_mode}" == "1" ]] && services+=" redis"
  fi

  [[ "${use_es}" == "1" ]] && services+=" es"
  [[ "${use_minio}" == "1" ]] && services+=" minio"
  [[ "${use_loki}" == "1" ]] && services+=" loki"

  echo "${services}"
}

function get_docker_compose_cmd_line() {
  ignore_db="$1"
  use_ipv6=$(get_config USE_IPV6)
  use_xpack=$(get_config_or_env USE_XPACK)
  https_port=$(get_config HTTPS_PORT)
  use_lb=$(get_config USE_LB)
  http_port=$(get_config HTTP_PORT)
  db_images_file=$(get_db_images_file)
  cap_addon=$(get_config CAP_ADDON)

  cmd="docker compose"
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd+=" -f compose/network.yml"
  else
    cmd+=" -f compose/network-v6.yml"
  fi
  services=$(get_docker_compose_services "ignore_db")

  for service in $services; do
      cmd+=" -f compose/${service}.yml"
  done

  db_yml=$(get_db_compose_yml)
  if [[ -n "${db_yml}" ]]; then
    cmd+=" ${db_yml}"
  fi

  if [[ "${use_lb}" == "1" ]]; then
    cmd+=" -f compose/web.https.yml"
  fi

  if [[ -n "${http_port}" && "${http_port}" != "0" ]];then
    cmd+=" -f compose/web.http.yml"
  fi

  if [[ "${cap_addon}" == "1" ]]; then
    cmd+=" -f compose/cap_addon.yml"
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


function get_latest_version() {
  curl -s 'https://api.github.com/repos/jumpserver/jumpserver/releases/latest' |
    grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' |
    sed 's/\"//g;s/,//g;s/ //g'
}

function get_db_compose_yml() {
  target=${1:-"all"}
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)
  ha_mode=$(get_config HA_MODE)
  db_images_file=$(get_db_info "file")

  if [[ -z "${target}" ]]; then
    target="all"
  fi

  cmd=""
  if [[ "${target}" == "all" || "${target}" == "db" ]]; then
      if [[ "${db_host}" == "mysql" || "${db_host}" == "postgresql" || "${ha_mode}" == "1" ]]; then
        db_images_file=$(get_db_images_file)
        cmd+=" -f ${db_images_file}"
      fi
  fi
  if [[ "${target}" == "all" || "${target}" == "redis" ]]; then
    if [[ "${redis_host}" == "redis" || "${ha_mode}" == "1" ]]; then
      cmd+=" -f compose/redis.yml"
      redis_expose_port=$(get_config REDIS_EXPOSE_PORT)
      if [[ -n "${redis_expose_port}" ]]; then
        cmd+=" -f compose/redis.port.yml"
      fi
    fi
  fi
  echo "${cmd}"
}


function get_db_compose_cmd() {
  target=${1:-"all"}
  use_ipv6=$(get_config USE_IPV6)
  use_xpack=$(get_config_or_env USE_XPACK)

  cmd="docker compose "
  yml=$(get_db_compose_yml)

  if [[ -n "${yml}" ]]; then
    cmd+=" ${yml}"
  fi
 
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd+=" -f compose/network.yml"
  else
    cmd+=" -f compose/network-v6.yml"
  fi
  echo "$cmd"
}

function get_db_migrate_compose_cmd() {
  cmd=$(get_db_compose_cmd "all")
  cmd+=" -f compose/init-db.yml"
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

function db_redis_start() {
  target=$1
  cmd=$(get_db_compose_cmd "${target}")
  ${cmd} up -d || {
    exit 1
  }
}

function db_redis_stop() {
  target=$1
  cmd=$(get_db_compose_cmd "${target}")
  ${cmd} down
}

function db_redis_restart() {
  db_redis_stop
  sleep 3
  db_redis_start
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