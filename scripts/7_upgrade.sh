#!/usr/bin/env bash
#
export SHELLOPTS

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"
. "${BASE_DIR}/2_install_docker.sh"

target=$1
UPGRADE_CONFIG_CHANGED=0
UPGRADE_DATABASE_MIGRATION_STARTED=0
UPGRADE_COMMITTED=0

function verify_upgrade_version() {
  required_version="v3.10.11"
  current_version=$(get_config CURRENT_VERSION)

  if [[ -z "${current_version}" ]]; then
    log_error "$(gettext 'The current version is not detected, please check')"
    return 1
  fi

  if ! [[ $current_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    return 0
  fi

  if [[ "${current_version}" != "${required_version}" ]] && \
    [[ "$(printf '%s\n' "$required_version" "$current_version" | sort -V | head -n1)" == "$current_version" ]]; then
    log_error "$(gettext 'Your current version does not meet the minimum requirements. Please upgrade') ${current_version} -> ${required_version}"
    return 1
  fi
}

function check_and_set_config() {
  local config_key=$1
  local default_value=$2
  local current_value=$(get_config ${config_key})
  if [ -z "${current_value}" ]; then
    set_config ${config_key} "${default_value}"
  fi
}

function migrate_compat_config() {
  local new_key=$1
  local old_key=$2
  local default_value=$3
  local new_value old_value

  new_value=$(get_config "${new_key}")
  if [[ -n "${new_value}" ]]; then
    remove_config "${old_key}"
    return
  fi

  old_value=$(get_config "${old_key}")
  if [[ -n "${old_value}" ]]; then
    set_config "${new_key}" "${old_value}"
    remove_config "${old_key}"
    return
  fi

  if [[ -n "${default_value}" ]]; then
    set_config "${new_key}" "${default_value}"
  fi

}

function migrate_database_expose_config() {
  local legacy_value legacy_host legacy_port

  legacy_value=$(get_config POSTGRESQL_EXPOSE_PORT)
  if [[ "${legacy_value}" =~ ^(\[[^]]+\]|[^:]+):([0-9]+)$ ]]; then
    legacy_host="${BASH_REMATCH[1]}"
    legacy_port="${BASH_REMATCH[2]}"
    if [[ -z "$(get_config POSTGRESQL_EXPOSE_HOST)" ]]; then
      set_config POSTGRESQL_EXPOSE_HOST "${legacy_host}"
    fi
    set_config POSTGRESQL_EXPOSE_PORT "${legacy_port}"
  fi

  check_and_set_config "POSTGRESQL_EXPOSE_HOST" "127.0.0.1"
  check_and_set_config "POSTGRESQL_EXPOSE_PORT" "5432"
  check_and_set_config "MYSQL_EXPOSE_HOST" "127.0.0.1"
  check_and_set_config "MYSQL_EXPOSE_PORT" "3306"
}

function verify_internal_mysql_root_password() {
  local password=$1 port=$2 output
  if output=$(printf '%s\n' "${password}" | docker exec -i jms_mysql sh -ceu '
    IFS= read -r password
    export MYSQL_PWD="${password}"
    exec mysql --protocol=tcp --connect-timeout=5 -h 127.0.0.1 -P "$1" -u root \
      --batch --skip-column-names -e "SELECT 1;"
  ' sh "${port}" 2>&1); then
    return 0
  fi
  # Authentication rejection proves that the server is already accepting
  # connections. Other failures may still be a database starting up.
  case "${output}" in
    *'ERROR 1045 '*|*'ERROR 1698 '*|*'ERROR 1130 '*) return 2 ;;
  esac
  return 1
}

function migrate_internal_mysql_root_password() {
  local engine host user root_password container_env candidate previous duplicate
  local container_state port timeout deadline server_ready credential_status seeded_root=0
  local -a root_candidates=()
  engine=$(get_config DB_ENGINE "mysql")
  host=$(get_config DB_HOST)
  [[ "${engine}" == [Mm][Yy][Ss][Qq][Ll] && "${host}" == "mysql" ]] || return 0

  user=$(get_config DB_USER)
  root_password=$(get_config MYSQL_ROOT_PASSWORD)
  # Snapshot this node's old environment before backup can recreate it.
  # Prefer MariaDB's alias, but authenticate every candidate before saving it.
  container_env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' jms_mysql 2>/dev/null || true)
  for candidate in "${root_password}" \
    "$(printf '%s\n' "${container_env}" | sed -n 's/^MARIADB_ROOT_PASSWORD=//p')" \
    "$(printf '%s\n' "${container_env}" | sed -n 's/^MYSQL_ROOT_PASSWORD=//p')" \
    "$(get_config MARIADB_ROOT_PASSWORD)"; do
    [[ -n "${candidate}" && "${candidate}" != *$'\n'* && "${candidate}" != *$'\r'* ]] || continue
    duplicate=0
    for previous in "${root_candidates[@]}"; do
      [[ "${candidate}" != "${previous}" ]] || duplicate=1
    done
    [[ "${duplicate}" == "1" ]] || root_candidates+=("${candidate}")
  done
  # Only a legacy standalone root login shared DB_PASSWORD. Application and
  # HA accounts never supply a fallback administrator credential.
  if [[ "${user}" == [Rr][Oo][Oo][Tt] && "$(get_config HA_MODE)" != "1" ]]; then
    candidate=$(get_config DB_PASSWORD)
    if [[ -n "${candidate}" && "${candidate}" != *$'\n'* && "${candidate}" != *$'\r'* ]]; then
      root_candidates+=("${candidate}")
    fi
  fi

  if (( ${#root_candidates[@]} > 0 )); then
    port=$(get_config DB_PORT 3306)
    container_state=$(docker inspect -f '{{.State.Status}}' jms_mysql 2>/dev/null || true)
    case "${container_state}" in
      created|exited) docker start jms_mysql >/dev/null || return 1 ;;
      '')
        # An absent old container has no environment left to preserve. Seed
        # startup from a local root candidate; existing data keeps its users.
        set_config MYSQL_ROOT_PASSWORD "${root_candidates[0]}" || return 1
        seeded_root=1
        db_redis_start db || return 1
        ;;
    esac
    timeout=$(get_config CONTAINER_HEALTH_TIMEOUT 300)
    [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=300
    deadline=$((SECONDS + timeout))
    while :; do
      server_ready=0
      for candidate in "${root_candidates[@]}"; do
        if verify_internal_mysql_root_password "${candidate}" "${port}"; then
          set_config MYSQL_ROOT_PASSWORD "${candidate}"
          return $?
        else
          credential_status=$?
        fi
        [[ "${credential_status}" != "2" ]] || server_ready=1
      done
      [[ "${server_ready}" == "0" ]] && (( SECONDS < deadline )) || break
      sleep 2
    done
  fi

  if [[ "${seeded_root}" == "1" ]]; then
    set_config MYSQL_ROOT_PASSWORD "${root_password}" || return 1
  fi
  if [[ "${user}" != [Rr][Oo][Oo][Tt] ]]; then
    # Existing application accounts need no administrator for schema upgrades.
    # Keep their credentials and let the business health check validate them.
    if (( ${#root_candidates[@]} > 0 )); then
      log_warn "Built-in MySQL root credential could not be verified; continuing with the existing application account"
    fi
    return 0
  fi
  log_error "Built-in MySQL root authentication failed; recover a valid local root credential before upgrading a legacy root login"
  return 1
}

function migrate_internal_mysql_business_account() {
  local engine host user database root_password business_password business_user
  engine=$(get_config DB_ENGINE "mysql")
  host=$(get_config DB_HOST)
  [[ "${engine}" == [Mm][Yy][Ss][Qq][Ll] && "${host}" == "mysql" ]] || return 0

  [[ "$(get_config HA_MODE)" != "1" ]] || return 0
  user=$(get_config DB_USER)
  [[ "${user}" == [Rr][Oo][Oo][Tt] ]] || return 0

  migrate_internal_mysql_root_password || return 1
  root_password=$(get_config MYSQL_ROOT_PASSWORD)

  database=$(get_config DB_NAME jumpserver)
  [[ "${database}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    log_error "Built-in MySQL database name is not safe for automatic account migration"
    return 1
  }
  docker inspect jms_mysql >/dev/null 2>&1 || {
    log_error "Built-in MySQL container is unavailable for application-account migration"
    return 1
  }
  business_password=$(random_str 32)
  business_user=$(printf '%s\n%s\n' "${root_password}" "${business_password}" | docker exec -i \
    -e JMS_MIGRATE_DB_NAME="${database}" -e JMS_MIGRATE_DB_PORT="$(get_config DB_PORT 3306)" \
    -e JMS_MIGRATE_DB_ALT_USER="jumpserver_$(random_str 12)" jms_mysql bash -ceu '
      IFS= read -r root_password
      IFS= read -r business_password
      [ -n "${root_password}" ] && [ -n "${business_password}" ]
      export MYSQL_PWD="${root_password}"
      mysql_args=(--protocol=tcp --connect-timeout=5 -h 127.0.0.1 -P "${JMS_MIGRATE_DB_PORT}" --batch --skip-column-names)
      quote="$(printf "\\047")"
      # Any same-name account could have broader privileges or a more-specific
      # host match. Leave it intact and create a fresh application identity.
      existing=$(mysql "${mysql_args[@]}" -u root -e "SELECT COUNT(*) FROM mysql.user WHERE User = ${quote}jumpserver${quote};" 2>/dev/null)
      business_user=jumpserver
      if [[ "${existing}" != "0" ]]; then
        business_user="${JMS_MIGRATE_DB_ALT_USER}"
      fi
      escaped_password="${business_password//${quote}/${quote}${quote}}"
      sql="CREATE USER ${quote}${business_user}${quote}@${quote}%${quote} IDENTIFIED BY ${quote}${escaped_password}${quote}; GRANT ALL PRIVILEGES ON \`${JMS_MIGRATE_DB_NAME}\`.* TO ${quote}${business_user}${quote}@${quote}%${quote};"
      printf "%s\n" "${sql}" | mysql "${mysql_args[@]}" -u root >/dev/null 2>&1
      MYSQL_PWD="${business_password}" mysql "${mysql_args[@]}" -u "${business_user}" \
        --database="${JMS_MIGRATE_DB_NAME}" -e "SELECT 1;" >/dev/null 2>&1
      printf "%s\n" "${business_user}"
    ') || {
      log_error "Failed to create the non-privileged built-in MySQL application account"
      return 1
    }
  set_config DB_USER "${business_user}"
  set_config DB_PASSWORD "${business_password}"
  echo_check "Migrated built-in MySQL from the root login to a dedicated JumpServer account"
}

function remove_obsolete_containers() {
  local container existing_containers
  local containers=("jms_guacamole" "jms_lina" "jms_luna" "jms_nginx" "jms_xpack" "jms_lb" "jms_omnidb" "jms_kael" "jms_magnus" "jms_video" "jms_lion" "jms_facelive" "jms_panda")

  # XRDP is still supported when explicitly enabled in the enterprise edition.
  if [[ "$(get_config_or_env USE_XPACK)" != "1" || "$(get_config_or_env XRDP_ENABLED)" != "1" ]]; then
    containers+=("jms_xrdp")
  fi
  existing_containers=$(docker ps -a --format '{{.Names}}') || return 1
  for container in "${containers[@]}"; do
    if grep -Fxq "${container}" <<<"${existing_containers}"; then
      if ! docker stop "${container}" >/dev/null || ! docker rm "${container}" >/dev/null; then
        log_error "Failed to remove obsolete container: ${container}"
        return 1
      fi
    fi
  done
}

function upgrade_config() {
  if check_root; then
    check_docker_start
  fi
  if ! docker ps &>/dev/null; then
    log_error "$(gettext 'Docker is not running, please install and start')"
    exit 1
  fi
  remove_obsolete_containers || return 1
  if docker ps -a | grep jms_xpack &>/dev/null; then
    docker volume rm jms_share-volume &>/dev/null
  fi
  if docker image inspect -f '{{.Id}}' jumpserver/mariadb:10.6 &>/dev/null; then
    docker tag jumpserver/mariadb:10.6 mariadb:10.6
  fi
  if docker image inspect -f '{{.Id}}' jumpserver/mysql:8.0 &>/dev/null; then
    docker tag jumpserver/mysql:8.0 mysql:8.0
  fi
  check_and_set_config "CURRENT_VERSION" "${VERSION}"
  check_and_set_config "CLIENT_MAX_BODY_SIZE" "4096m"
  check_and_set_config "SERVER_HOSTNAME" "${HOSTNAME}"
  check_and_set_config "JUMPSERVER_ENABLE_FONT_SMOOTHING" "true"
  check_and_set_config "KOKO_WEB_PROXY_PORT" "5001"
  check_and_set_config "WEB_PROXY_ALLOWED_HOSTS" "localhost,127.0.0.1"
  migrate_database_expose_config
  migrate_internal_mysql_business_account || return 1
  check_and_set_config "USE_LB" "1"
  check_and_set_config "VERIFY_EXTERNAL_SSL" "false"
  # XPACK
  use_xpack=$(get_config_or_env USE_XPACK)
  if [[ "${use_xpack}" == "1" ]]; then
    check_and_set_config "XRDP_ENABLED" "0"
    if [[ "$(get_config_or_env XRDP_ENABLED)" == "1" ]]; then
      check_and_set_config "XRDP_PORT" "3390"
    fi
    check_and_set_config "MAGNUS_PORT" "5525"
  fi
}

function clean_file() {
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -f "${volume_dir}/core/data/flower" ]]; then
    rm -f "${volume_dir}/core/data/flower"
  fi
  if [[ -f "${volume_dir}/core/data/flower.db" ]]; then
    rm -f "${volume_dir}/core/data/flower.db"
  fi
}

function migrate_coco_to_koko() {
  volume_dir=$(get_config VOLUME_DIR)
  coco_dir="${volume_dir}/coco"
  koko_dir="${volume_dir}/koko"
  if [[ ! -d "${koko_dir}" && -d "${coco_dir}" ]]; then
    mv "${coco_dir}" "${koko_dir}"
    ln -s "${koko_dir}" "${coco_dir}"
  fi
}

function migrate_config_v1_5_to_v2_0() {
  if [[ ! -f ${CONFIG_FILE} ]]; then
    mkdir -p "${CONFIG_DIR}"

    # v1.5 => v2.0
    # 原先配置文件都在自己的目录，以后配置文件统一放在 /opt/jumpserver/config 中
    if [[ -f config.txt ]]; then
      mv config.txt "${CONFIG_FILE}"
      rm -f .env
    fi
  fi
}

function migrate_config_v2_0_to_v3_0() {
  is_running=0
  for app in jms_lb jms_nginx jms_web; do
    if docker ps | grep -q "${app}"; then
      is_running=1
      break
    fi
  done

  if [ "$is_running" -eq 0 ]; then
    # Nothing to do
    return
  fi

  https_port=$(get_config HTTPS_PORT)
  use_https=0

  for app in jms_lb jms_nginx jms_web; do
    if docker ps -a | grep "${app}" &>/dev/null; then
      if [[ -n "${https_port}" ]]; then
        if docker inspect --format='{{.NetworkSettings.Ports}}' "${app}" | grep -w "${https_port}" &>/dev/null; then
          use_https=1
        fi
      fi
    fi
  done

  if [[ "${use_https}" == "0" ]]; then
    if [[ -n "${https_port}" ]]; then
      sed -i "s/^HTTPS_PORT=/# HTTPS_PORT=/g" "${CONFIG_FILE}"
    fi
  fi
}

function migrate_data_folder() {
  local volume_dir legacy_video_dir video_worker_dir
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -d "${volume_dir}/core/logs" ]] && [[ ! -d "${volume_dir}/core/data/logs" ]]; then
    mv "${volume_dir}/core/logs" "${volume_dir}/core/data/logs"
  fi
  legacy_video_dir="${volume_dir}/video"
  video_worker_dir="${volume_dir}/video-worker"
  if [[ -d "${legacy_video_dir}" && ! -e "${video_worker_dir}" ]]; then
    mv "${legacy_video_dir}" "${video_worker_dir}" || return 1
    ln -s "${video_worker_dir}" "${legacy_video_dir}" || return 1
  elif [[ -L "${legacy_video_dir}" && -e "${video_worker_dir}" ]] && \
    [[ "$(readlink -f "${legacy_video_dir}")" == "$(readlink -f "${video_worker_dir}")" ]]; then
    :
  elif [[ -d "${legacy_video_dir}" && -e "${video_worker_dir}" ]]; then
    log_warn "Both ${legacy_video_dir} and ${video_worker_dir} exist; keeping both"
  fi
}

function migrate_config() {
  local component

  prepare_jmsctl
  migrate_compat_config "KOKO_SSH_PORT" "SSH_PORT" "2222"
  migrate_compat_config "RAZOR_RDP_PORT" "RDP_PORT" "3389"
  migrate_compat_config "VIDEO_WORKER_ENABLED" "VIDEO_ENABLED" ""
  migrate_compat_config "VIDEO_WORKER_ENABLED" "VIDEO_ENABLE" ""
  for component in CORE AI CELERY KOKO CHEN WEB MAGNUS RAZOR XRDP NEC; do
    migrate_compat_config "${component}_ENABLED" "${component}_ENABLE" ""
  done
}

function update_config_if_need() {
  migrate_config_v1_5_to_v2_0
  migrate_config_v2_0_to_v3_0
  migrate_coco_to_koko
  migrate_config
  upgrade_config || exit 1
  set_openbao || exit 1
  migrate_data_folder || exit 1
  clean_file
}

function backup_config() {
  VOLUME_DIR=$(get_config VOLUME_DIR)
  BACKUP_DIR="${VOLUME_DIR}/db_backup"
  CURRENT_VERSION=$(get_config CURRENT_VERSION)
  backup_config_file="${BACKUP_DIR}/config-${CURRENT_VERSION}-$(date +%F_%T).conf"
  if [[ ! -d ${BACKUP_DIR} ]]; then
    mkdir -p "${BACKUP_DIR}" || return 1
  fi
  cp "${CONFIG_FILE}" "${backup_config_file}" || return 1
  echo "$(gettext 'Back up to') ${backup_config_file}"
}

function persist_installer_version() {
  local tmp_file line
  local replaced=0

  tmp_file=$(mktemp "${STATIC_ENV}.tmp.XXXXXX") || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?VERSION= ]]; then
      if [[ "${replaced}" == "0" ]]; then
        printf 'export VERSION=%s\n' "${VERSION}"
        replaced=1
      fi
    else
      printf '%s\n' "${line}"
    fi
  done <"${STATIC_ENV}" >"${tmp_file}"
  if [[ "${replaced}" == "0" ]]; then
    printf 'export VERSION=%s\n' "${VERSION}" >>"${tmp_file}"
  fi
  mv -f "${tmp_file}" "${STATIC_ENV}"
}

function write_upgrade_recovery_state() {
  local state=$1 tmp_file
  [[ -n "${JDMC_UPGRADE_LOG_DIR:-}" ]] || return 0

  tmp_file=$(mktemp "${JDMC_UPGRADE_LOG_DIR}/installer-recovery.XXXXXX") || return 1
  if ! printf '%s\n' "${state}" >"${tmp_file}" || ! sync "${tmp_file}" || \
    ! mv -f "${tmp_file}" "${JDMC_UPGRADE_LOG_DIR}/installer-recovery" || \
    ! sync "${JDMC_UPGRADE_LOG_DIR}"; then
    rm -f "${tmp_file}"
    return 1
  fi
}

function cleanup_failed_upgrade() {
  local status=$? safe_to_restore=1

  if [[ "${status}" != "0" && "${UPGRADE_COMMITTED}" != "1" ]]; then
    if [[ "${UPGRADE_CONFIG_CHANGED}" == "1" && \
      "${UPGRADE_DATABASE_MIGRATION_STARTED}" == "0" && \
      -f "${backup_config_file:-}" ]]; then
      if cp "${backup_config_file}" "${CONFIG_FILE}" && gen_safe_config >/dev/null; then
        log_warn "Upgrade failed before database migration; restored ${CONFIG_FILE}"
      else
        safe_to_restore=0
        log_error "Upgrade failed and ${CONFIG_FILE} could not be restored from ${backup_config_file}"
      fi
    elif [[ "${UPGRADE_DATABASE_MIGRATION_STARTED}" == "1" ]]; then
      safe_to_restore=0
      log_warn "Upgrade stopped after database migration began; keep the upgraded configuration and retry the upgrade"
      log_warn "Pre-upgrade configuration backup: ${backup_config_file:-unknown}"
    elif [[ "${UPGRADE_CONFIG_CHANGED}" == "1" ]]; then
      safe_to_restore=0
      log_error "Pre-upgrade configuration backup is missing; manual recovery is required"
    fi
    if [[ "${safe_to_restore}" == "1" ]]; then
      write_upgrade_recovery_state safe_to_restore || log_error "Failed to persist upgrade recovery state"
    else
      write_upgrade_recovery_state recovery_required || log_error "Failed to persist upgrade recovery state"
    fi
  fi

  trap - EXIT
  exit "${status}"
}

function backup_db() {
  local db_image external_mysql=0

  if [[ "${SKIP_BACKUP_DB:-0}" != "1" ]]; then
    db_image=$(get_db_images)
    if is_external_mysql_image "${db_image}"; then
      external_mysql=1
      # Do not let docker run implicitly pull a missing client in offline upgrades.
      if ! reuse_legacy_db_image "${db_image}"; then
        log_warn "External MySQL backup image ${db_image} is unavailable; skipping database backup and continuing upgrade. No installer database backup was created."
        return 0
      fi
    fi
    if ! bash "${SCRIPT_DIR}/5_db_backup.sh"; then
      if [[ "${external_mysql}" == "1" ]]; then
        log_warn 'Failed to back up external MySQL; continuing upgrade without a successful installer database backup.'
        return 0
      fi
      confirm="n"
      read_from_input confirm "$(gettext 'Failed to backup the database. Continue to upgrade')?" "y/n" "${confirm}"
      if [[ "${confirm}" == "n" ]]; then
        exit 1
      fi
    fi
  else
    echo "SKIP_BACKUP_DB=${SKIP_BACKUP_DB}, $(gettext 'Skip database backup')"
  fi
}

function db_migrations() {
  local role="${ROLE:-master}"
  if [[ "${role,,}" == "standby" ]]; then
     echo "Role is standby, skip database migrations"
     return 
  fi
  if docker ps | grep -E "core|koko"&>/dev/null; then
    confirm="y"
    read_from_input confirm "$(gettext 'Detected that the JumpServer container is running. Do you want to close the container and continue to upgrade')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      echo
      cd "${PROJECT_DIR}" || exit 1
      bash ./jmsctl.sh stop || {
        log_error "Failed to stop JumpServer containers before database migration"
        exit 1
      }
      sleep 2s
      echo
    else
      exit 1
    fi
  fi
  if ! perform_db_migrations; then
    log_error "$(gettext 'Failed to change the table structure')!"
    confirm="n"
    read_from_input confirm "$(gettext 'Failed to change the table structure. Continue to upgrade')?" "y/n" "${confirm}"
    if [[ "${confirm}" != "y" ]]; then
      exit 1
    fi
  fi
}

function clean_images() {
  current_version=$(get_config CURRENT_VERSION)

  if [[ -z "${to_version}" || -z "${current_version}" ]];then
    echo "to_version or current_version is empty, skip clean images"
    return
  fi

  if [[ "${current_version}" == "${to_version}" ]]; then
    echo "current_version is equal to to_version, skip clean images"
    return
  fi

  namespace=$(get_config_or_env NAMESPACE jumpserver)
  namespace=${namespace%/}
  old_images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "${namespace}/" | grep "${current_version}" || true)
  if [[ -n "${old_images}" ]]; then
    confirm="y"
    read_from_input confirm "$(gettext 'Do you need to clean up the old version image')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      echo "${old_images}" | xargs docker rmi -f || true
    fi
  fi
}

function upgrade_docker() {
  if check_root && [[ -f "/usr/local/bin/docker" ]]; then
    if ! /usr/local/bin/docker -v | grep ${DOCKER_VERSION} &>/dev/null; then
      echo -e "$(docker -v) \033[33m-->\033[0m Docker version \033[32m${DOCKER_VERSION}\033[0m"
      confirm="n"
      read_from_input confirm "$(gettext 'Do you need upgrade Docker binaries')?" "y/n" "${confirm}"
      if [[ "${confirm}" == "y" ]]; then
        echo
        cd "${PROJECT_DIR}" || exit 1
        bash ./jmsctl.sh down
        sleep 2s
        echo
        systemctl stop docker
        cd "${BASE_DIR}" || exit 1
        install_docker
        check_docker_install
        check_docker_start
      fi
    fi
  fi
}

function upgrade_compose() {
  if check_root && [[ -f "/usr/local/libexec/docker/cli-plugins/docker-compose" || -f "$HOME/.docker/cli-plugins/docker-compose" ]]; then
    if ! docker compose version | grep ${DOCKER_COMPOSE_VERSION} &>/dev/null; then
      echo
      echo -e "$(docker compose version) \033[33m-->\033[0m Docker Compose version \033[32m${DOCKER_COMPOSE_VERSION}\033[0m"
      confirm="n"
      read_from_input confirm "$(gettext 'Do you need upgrade Docker Compose')?" "y/n" "${confirm}"
      if [[ "${confirm}" == "y" ]]; then
        echo
        cd "${BASE_DIR}" || exit 1
        check_compose_install
        check_docker_compose
      fi
    fi
  fi
}

function main() {
  local installer_version_before_upgrade target_version
  trap cleanup_failed_upgrade EXIT
  write_upgrade_recovery_state running || exit 1
  cd "${PROJECT_DIR}" || exit 1

  confirm="y"
  installer_version_before_upgrade=${VERSION}
  to_version="${VERSION}"
  if [[ -n "${target}" ]]; then
    to_version="${target}"
  fi
  # Extract suffix from the original VERSION (e.g., -ce, -ee)
  # The suffix is the part after the first hyphen.
  # Example: VERSION="v3.10.11-ce" -> ori_suffix_part="-ce"
  # Example: VERSION="v3.10.11"    -> ori_suffix_part=""
  ori_suffix_part=$(echo "$VERSION" | grep -o -- '-.*' || true)

  # Check if to_version already has a suffix
  # Example: to_version="v3.11.0-ce" -> to_has_suffix will be non-empty
  # Example: to_version="v3.11.0"    -> to_has_suffix will be empty
  to_has_suffix=$(echo "$to_version" | grep -o -- '-.*' || true)

  # If to_version does not have a suffix, but the original VERSION did, append it.
  if [[ -z "${to_has_suffix}" && -n "${ori_suffix_part}" ]]; then
    to_version="${to_version}${ori_suffix_part}"
  fi

  if [[ ! "${to_version}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    log_error "Invalid target version: ${to_version}"
    exit 1
  fi

  read_from_input confirm "$(gettext 'Are you sure you want to update the current version to') ${to_version} ?" "y/n" "${confirm}"
  if [[ "${confirm}" != "y" || -z "${to_version}" ]]; then
    exit 3
  fi

  export VERSION="${to_version}"
  echo
  verify_upgrade_version || exit 1
  echo
  check_compose_install

  echo_yellow "\n2. $(gettext 'Backup Configuration File')"
  if ! backup_config; then
    log_error "Failed to back up the configuration file"
    exit 1
  fi
  # Database backup starts a Core container using the target version.
  # Load the offline images before that container is created.
  echo_yellow "\n3. $(gettext 'Loading Docker Image')"
  if ! ALLOW_MISSING_DB_IMAGE=1 bash "${BASE_DIR}/3_load_images.sh"; then
    log_error "$(gettext 'Failed to load Docker images')"
    exit 1
  fi

  echo_yellow "\n4. $(gettext 'Backup database')"
  UPGRADE_CONFIG_CHANGED=1
  migrate_internal_mysql_root_password || exit 1
  backup_db

  echo_yellow "\n5. $(gettext 'Update Configuration File')"
  update_config_if_need
  configure_jdmc || {
    log_error "Failed to configure JDMC"
    exit 1
  }

  echo_yellow "\n6. $(gettext 'Apply database changes')"
  echo "$(gettext 'Changing database schema may take a while, please wait patiently')"
  write_upgrade_recovery_state recovery_required || exit 1
  UPGRADE_DATABASE_MIGRATION_STARTED=1
  db_migrations

  echo_yellow "\n7. $(gettext 'Upgrade Docker')"
  upgrade_docker
  upgrade_compose
  ensure_current_installer_link || {
    log_error "Failed to update /opt/current/installer"
    exit 1
  }
  upgrade_jdmc || {
    jdmc_status=$?
    log_error "Failed to upgrade JDMC"
    exit "${jdmc_status}"
  }

  persist_installer_version || {
    log_error "Failed to update ${STATIC_ENV}"
    exit 1
  }
  if ! set_current_version; then
    target_version=${VERSION}
    VERSION=${installer_version_before_upgrade}
    persist_installer_version || log_warn "Failed to roll back ${STATIC_ENV}"
    VERSION=${target_version}
    log_error "Failed to update CURRENT_VERSION"
    exit 1
  fi
  UPGRADE_COMMITTED=1
  trap - EXIT
  installation_log "upgrade"

  echo_yellow "\n8. $(gettext 'Cleanup Image')"
  clean_images

  echo_yellow "\n9. $(gettext 'Upgrade successfully. You can now restart the program')"
  echo "cd ${PROJECT_DIR}"
  echo "./jmsctl.sh start"
  echo -e "\n"
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
