. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/postgresql-upgrade-standalone.sh"

common_services=(core kael celery ansible-executor koko chen web)
xpack_services=(magnus razor xrdp video-worker nec)


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

function get_db_images_file() {
  get_db_info "file"
}

function get_internal_postgresql_data_version() {
  local volume_dir version_file data_version
  [[ "$(get_config DB_ENGINE)" == "postgresql" ]] || return 0
  [[ "$(get_config DB_HOST)" == "postgresql" || "$(get_config HA_MODE)" == "1" ]] || return 0
  volume_dir=$(get_config VOLUME_DIR)
  [[ -n "${volume_dir}" ]] || return 0
  version_file="${volume_dir}/postgresql/data/PG_VERSION"
  [[ -e "${version_file}" ]] || return 0
  data_version=$(cat "${version_file}") || return 1
  [[ "${data_version}" =~ ^[1-9][0-9]$ ]] || {
    log_error "Cannot determine the existing PostgreSQL major version from ${version_file}"
    return 1
  }
  printf '%s\n' "${data_version}"
}

function get_postgresql_image() {
  local image data_version container_image candidate
  image=postgres:18.6-bookworm
  data_version=$(get_internal_postgresql_data_version) || return 1
  if [[ -n "${data_version}" && ! "${image}" =~ ^postgres:${data_version}([.-]|$) ]]; then
    # Keep the installed patch/OS variant when the old container still exists.
    container_image=$(docker inspect -f '{{.Config.Image}}' jms_postgresql 2>/dev/null || true)
    if [[ ! "${container_image}" =~ ^postgres:${data_version}([.-]|$) ]]; then
      # A stopped/removed container must not force an offline upgrade to fetch
      # a different patch when a compatible local PostgreSQL image remains.
      while IFS= read -r candidate; do
        if [[ "${candidate}" =~ ^postgres:${data_version}([.-]|$) ]]; then
          container_image=${candidate}
          break
        fi
      done < <(docker image ls --filter "reference=postgres:${data_version}*" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
    fi
    if [[ "${container_image}" =~ ^postgres:${data_version}([.-]|$) ]]; then
      image=${container_image}
    else
      case "${data_version}" in
        16) image=postgres:16.15-bookworm ;;
        17) image=postgres:17.11-bookworm ;;
        18) image=postgres:18.6-bookworm ;;
        *) image="postgres:${data_version}-bookworm" ;;
      esac
    fi
  fi
  printf '%s\n' "${image}"
}

function get_postgresql_compose_files() {
  local image directory file content tmp
  image=$(get_postgresql_image) || return 1
  if [[ "${image}" == postgres:18.6-bookworm ]]; then
    printf 'compose/postgresql.yml -f compose/postgresql.port.yml\n'
    return 0
  fi
  # Old data still needs its matching image until migration finishes. Keep the
  # release Compose fixed at 18 and record this runtime override in its labels,
  # so JDMC can render the same files without any image configuration variable.
  [[ "${image}" =~ ^postgres:[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || return 1
  directory="${CONFIG_DIR}/postgresql"
  file="${directory}/image-${image#postgres:}.yml"
  content=$(printf 'services:\n  postgresql:\n    image: %s\n' "${image}")
  [[ ! -L "${directory}" && ! -L "${file}" ]] || return 1
  mkdir -p -m 700 "${directory}" || return 1
  # A captured JDMC Compose binding may still reference this file. Never
  # rewrite or delete it when the selected database version changes.
  if [[ -e "${file}" ]]; then
    [[ -f "${file}" && "$(cat "${file}")" == "${content}" ]] || return 1
  else
    tmp=$(mktemp "${directory}/.image.XXXXXX") || return 1
    if ! { printf '%s\n' "${content}" >"${tmp}" && chmod 600 "${tmp}" && mv "${tmp}" "${file}"; }; then
      rm -f "${tmp}"
      return 1
    fi
  fi
  printf 'compose/postgresql.yml -f compose/postgresql.port.yml -f %s\n' "${file}"
}

function prepare_postgresql_parent_directory() {
  # The shared Compose now binds PGDATA's parent even while using an old image.
  # Allow the container's postgres UID to traverse it without opening PGDATA.
  # Existing HA mounts and permissions are changed only by coordinated cutover.
  [[ "$(get_config DB_HOST)" == postgresql && "$(get_config HA_MODE)" != 1 ]] || return 0
  local volume_dir parent mode
  volume_dir=$(get_config VOLUME_DIR)
  [[ -n "${volume_dir}" ]] || return 0
  parent="${volume_dir}/postgresql"
  [[ -d "${parent}" ]] || return 0
  [[ ! -L "${parent}" ]] || return 1
  mode=$(stat -Lc '%a' -- "${parent}") || return 1
  (( (8#${mode} & 0111) == 0111 )) || chmod a+x -- "${parent}"
}

function get_db_info() {
  local db_image
  info_type=$1
  db_engine=$(get_config DB_ENGINE "mysql")
  db_host=$(get_config DB_HOST)
  db_image=$(get_config DB_IMAGE "mariadb:10.6")
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
        mariadb_data_exists=$(check_db_data "mariadb")
      fi
      if [[ "${mysql_data_exists}" != "1" && "${mariadb_data_exists}" != "1" ]]; then
        case "${db_image}" in
          mysql:8.0) mysql_data_exists="1" ;;
          mariadb:10.6) mariadb_data_exists="1" ;;
          *)
            log_error "Unsupported built-in database image: ${db_image}"
            return 1
            ;;
        esac
      fi
      ;;
    "postgresql")
      postgres_data_exists="1"
      db_image=$(get_postgresql_image) || return 1
      ;;
  esac

  case "${info_type}" in
    "image")
      if [[ "${mysql_data_exists}" == "1" ]]; then
        echo "mysql:8.0"
      elif [[ "${mariadb_data_exists}" == "1" ]]; then
        echo "mariadb:10.6"
      elif [[ "${postgres_data_exists}" == "1" ]]; then
        echo "${db_image}"
      fi
      ;;
    "file")
      if [[ "${mysql_data_exists}" == "1" ]]; then
        echo "compose/mysql.yml -f compose/mysql.port.yml"
      elif [[ "${mariadb_data_exists}" == "1" ]]; then
        echo "compose/mariadb.yml -f compose/mysql.port.yml"
      elif [[ "${postgres_data_exists}" == "1" ]]; then
        prepare_postgresql_parent_directory || return 1
        get_postgresql_compose_files || return 1
      fi
      ;;
    *)
      exit 1 ;;
  esac
}


function get_docker_compose_services() {
  ignore_db=${1-}
  db_engine=$(get_config DB_ENGINE "mysql")
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)
  redis_expose_port=$(get_config REDIS_EXPOSE_PORT)
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
    [[ "${redis_host}" == "redis" || "${ha_mode}" == "1" || -n "${redis_expose_port}" ]] && services+=" redis"
  fi

  [[ "${use_es}" == "1" ]] && services+=" es"
  [[ "${use_minio}" == "1" ]] && services+=" minio"
  [[ "${use_loki}" == "1" ]] && services+=" loki"
  if is_internal_openbao_enabled; then
    services+=" openbao"
  fi

  echo "${services}"
}

function get_docker_compose_cmd_line() {
  postgresql_upgrade_start_guard || return 1
  ignore_db=${1-}
  use_ipv6=$(get_config USE_IPV6)
  https_port=$(get_config HTTPS_PORT)
  http_port=$(get_config HTTP_PORT)
  cap_addon=$(get_config CAP_ADDON)

  cmd="docker compose"
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd+=" -f compose/network.yml"
  else
    cmd+=" -f compose/network-v6.yml"
  fi
  services=$(get_docker_compose_services "ignore_db")

  for service in $services; do
      if [[ "${service}" == "ansible-executor" ]]; then
        local executor_tag
        executor_tag=$(get_ansible_executor_tag) || return 1
        cmd="env ANSIBLE_EXECUTOR_TAG=${executor_tag} ${cmd}"
      fi
      cmd+=" -f compose/${service}.yml"
  done

  if [[ "${ignore_db}" != "ignore_db" ]]; then
    db_yml=$(get_db_compose_yml) || return 1
    if [[ -n "${db_yml}" ]]; then
      cmd+=" ${db_yml}"
    fi
  fi

  if [[ -n "${https_port}" && "${https_port}" != "0" ]]; then
    cmd+=" -f compose/web.https.yml"
  fi

  if [[ -n "${http_port}" && "${http_port}" != "0" ]]; then
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

function video_worker_can_start() {
  [[ "$(get_config_or_env USE_XPACK)" == "1" && \
     "$(get_config_or_env VIDEO_WORKER_ENABLED)" != "0" ]]
}

function stop_disabled_video_worker() {
  local container_id
  video_worker_can_start && return 0

  # Compose does not remove services omitted from a later `up -d`. Remove only
  # this installer's old video-worker container; keep its bind-mounted data.
  container_id=$(docker ps -a -q \
    --filter 'name=^/jms_video-worker$' \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-jms}" \
    --filter 'label=com.docker.compose.service=video-worker') || return 1
  if [[ -n "${container_id}" ]]; then
    docker container rm -f "${container_id}" >/dev/null || return 1
  fi
}

function prepare_services_for_start() {
  local service enabled container image owner running metadata extra from_containers=0
  if [[ "${1:-}" == --containers ]]; then
    from_containers=1
    shift
    (( $# > 0 )) || {
      log_error 'prepare --containers requires at least one container'
      return 1
    }
  fi
  local -a selected=("$@")
  if (( $# == 0 )); then
    enabled=$(get_enabled_services) || return 1
    read -r -a selected <<<"${enabled}"
  fi
  for service in "${selected[@]}"; do
    image='' owner=''
    if [[ "${from_containers}" == 1 ]]; then
      container=${service}
      [[ "${container}" =~ ^/?jms_[A-Za-z0-9_.-]+$ ]] || return 1
      metadata=$(docker inspect -f '{{.State.Running}}|{{.Image}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.User}}' "${container}") || return 1
      IFS='|' read -r running image service owner extra <<<"${metadata}"
      [[ "${running}" == false && "${image}" =~ ^sha256:[a-f0-9]{64}$ && \
        "${service}" =~ ^[A-Za-z0-9_.-]+$ && -z "${extra}" ]] || {
        log_error "Cannot prepare a running or invalid service container: ${container}"
        return 1
      }
    fi
    case "${service#jms_}" in
      chen) prepare_chen_volume "${image}" "${owner}" || return 1 ;;
      video-worker) prepare_video_worker_volume "${image}" "${owner}" || return 1 ;;
      ansible-executor|ansible_executor) prepare_ansible_executor "${image}" || return 1 ;;
    esac
  done
}

function prepare_chen_volume() {
  [[ "$(get_config_or_env CHEN_ENABLED)" != "0" ]] || return 0
  local image owner data_dir folder
  image=${1:-"$(get_image_namespace)/chen:${VERSION}"}
  owner=${2:-}
  if [[ -z "${owner}" ]]; then
    owner=$(docker image inspect -f '{{.Config.User}}' "${image}") || {
      log_error "Unable to inspect Chen image user: ${image}"
      return 1
    }
  fi
  # Legacy Java images run as root and need no ownership migration.
  case "${owner}" in ''|root|root:root|0|0:0) return 0 ;; esac
  if [[ ! "${owner}" =~ ^[0-9]+:[0-9]+$ ]]; then
    owner=$(docker run --rm --network none --user "${owner}" --entrypoint /bin/sh "${image}" -c \
      'printf "%s:%s\n" "$(id -u)" "$(id -g)"') || return 1
  fi
  if [[ ! "${owner}" =~ ^[0-9]+:[0-9]+$ ]]; then
    log_error "Invalid Chen image user: ${owner}"
    return 1
  fi
  data_dir="$(get_config VOLUME_DIR)/chen/data"
  # Only Chen's runtime state is writable. Leave the shared certificate mount
  # and legacy application files alone; never follow a state-directory symlink.
  for folder in "${data_dir}" "${data_dir}/keys" "${data_dir}/logs" "${data_dir}/go"; do
    if [[ -L "${folder}" ]]; then
      log_error "Chen state directory must not be a symbolic link: ${folder}"
      return 1
    fi
  done
  mkdir -p -m 700 "${data_dir}/keys" "${data_dir}/logs" "${data_dir}/go" || return 1
  chown -h "${owner}" "${data_dir}" || return 1
  chown -hR "${owner}" "${data_dir}/keys" "${data_dir}/logs" "${data_dir}/go" || return 1
}

function prepare_video_worker_volume() {
  local volume_dir data_dir image user_spec owner
  if ! video_worker_can_start; then
    return 0
  fi

  volume_dir=$(get_config VOLUME_DIR)
  data_dir="${volume_dir}/video-worker/data"
  mkdir -p "${data_dir}" || return 1

  image=${1:-"$(get_image_namespace)/video-worker:${VERSION}"}
  user_spec=${2:-}
  if [[ -z "${user_spec}" ]]; then
    user_spec=$(docker image inspect -f '{{.Config.User}}' "${image}") || {
      log_error "Unable to inspect video-worker image user: ${image}"
      return 1
    }
  fi
  if [[ "${user_spec}" =~ ^[0-9]+:[0-9]+$ ]]; then
    owner=${user_spec}
  else
    owner=$(docker run --rm --network none --user "${user_spec:-0}" --entrypoint /bin/sh "${image}" -c \
      'printf "%s:%s\n" "$(id -u)" "$(id -g)"') || {
      log_error "Unable to resolve video-worker image user: ${image}"
      return 1
    }
  fi
  if [[ ! "${owner}" =~ ^[0-9]+:[0-9]+$ ]]; then
    log_error "Invalid video-worker image user: ${owner}"
    return 1
  fi

  # Docker creates a missing bind-mount source as root. Match the directory to
  # the actual image user so image UID/GID changes do not break persistence.
  if [[ "$(stat -c '%u:%g' "${data_dir}")" != "${owner}" ]]; then
    chown -R "${owner}" "${data_dir}" || return 1
  fi
}


function remove_stopped_openbao_init_container() {
  # openbao-init is a one-shot dependency. Remove its completed container so it
  # does not remain in `docker ps -a`; a still-running initializer is preserved.
  docker container rm jms_openbao_init &>/dev/null || true
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
  db_images_file=$(get_db_info "file") || return 1
  redis_expose_port=$(get_config REDIS_EXPOSE_PORT)

  if [[ -z "${target}" ]]; then
    target="all"
  fi

  cmd=""
  if [[ "${target}" == "all" || "${target}" == "db" ]]; then
      if [[ "${db_host}" == "mysql" || "${db_host}" == "postgresql" || "${ha_mode}" == "1" ]]; then
        db_images_file=$(get_db_images_file) || return 1
        cmd+=" -f ${db_images_file}"
      fi
  fi
  if [[ "${target}" == "all" || "${target}" == "redis" ]]; then
    if [[ "${redis_host}" == "redis" || "${ha_mode}" == "1" || -n "${redis_expose_port}" ]]; then
      cmd+=" -f compose/redis.yml"
      if [[ -n "${redis_expose_port}" ]]; then
        cmd+=" -f compose/redis.port.yml"
      fi
    fi
  fi
  echo "${cmd}"
}


function get_db_compose_cmd() {
  postgresql_upgrade_start_guard || return 1
  target=${1:-"all"}
  use_ipv6=$(get_config USE_IPV6)
  use_xpack=$(get_config_or_env USE_XPACK)

  cmd="docker compose "
  yml=$(get_db_compose_yml "${target}") || return 1

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
  cmd=$(get_db_compose_cmd "all") || return 1
  cmd+=" -f compose/init-db.yml"
  echo "$cmd"
}

function create_db_ops_env() {
  cmd=$(get_db_migrate_compose_cmd) || return 1
  ${cmd} up -d || {
    return 1
  }
}

function down_db_ops_env() {
  docker stop jms_core &>/dev/null
  docker rm jms_core &>/dev/null
}

function db_redis_start() {
  target=$1
  cmd=$(get_db_compose_cmd "${target}") || return 1
  ${cmd} up -d || {
    return 1
  }
}

function db_redis_stop() {
  target=$1
  cmd=$(get_db_compose_cmd "${target}")
  ${cmd} down
}

function db_redis_restart() {
  local target=$1
  db_redis_stop "${target}" || return 1
  sleep 3
  db_redis_start "${target}"
}

function wait_container_healthy() {
  local container=$1
  local timeout=${2:-$(get_config CONTAINER_HEALTH_TIMEOUT 300)}
  local interval=${3:-5}
  local deadline status

  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=300
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval=5
  deadline=$((SECONDS + timeout))

  while ((SECONDS <= deadline)); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "${container}" 2>/dev/null || true)
    if [[ "${status}" == "healthy" ]]; then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      break
    fi
    echo "Waiting for ${container} to be healthy (${status:-not found})..."
    sleep "${interval}"
  done

  log_error "Timed out waiting for ${container} to become healthy after ${timeout}s"
  docker logs --tail 50 "${container}" >&2 2>/dev/null || true
  return 1
}

function perform_db_migrations() {
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)

  create_db_ops_env || return 1
  case "${db_host}" in
    mysql|postgresql)
      wait_container_healthy "jms_${db_host}" || return 1
      ;;
  esac

  if [[ "${redis_host}" == "redis" ]]; then
    wait_container_healthy jms_redis || return 1
  fi

  docker exec -i jms_core bash -c './jms upgrade_db' || {
    log_error "$(gettext 'Failed to change the table structure')!"
    return 1
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
  local telemetry_enabled
  telemetry_enabled=$(get_config INSTALLATION_TELEMETRY_ENABLED true)
  case "${telemetry_enabled}" in
    0|false|False|FALSE|no|No|NO) return 0 ;;
  esac
  if [ -d "${BASE_DIR}/images" ]; then
    return
  fi
  product=js
  install_type=$1
  version=$(get_current_version)
  url="https://community.fit2cloud.com/installation-analytics?product=${product}&type=${install_type}&version=${version}"
  curl -fsS --connect-timeout 5 -m 10 "${url}" &>/dev/null
}
