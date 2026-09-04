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

function upgrade_config() {
  if check_root; then
    check_docker_start
  fi
  if ! docker ps &>/dev/null; then
    log_error "$(gettext 'Docker is not running, please install and start')"
    exit 1
  fi
  local containers=("jms_guacamole" "jms_lina" "jms_luna" "jms_nginx" "jms_xpack" "jms_lb" "jms_omnidb" "jms_kael" "jms_magnus" "jms_video")
  for container in "${containers[@]}"; do
    if docker ps -a | grep ${container} &>/dev/null; then
      docker stop ${container} &>/dev/null
      docker rm ${container} &>/dev/null
    fi
  done
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
  check_and_set_config "USE_LB" "1"
  check_and_set_config "VERIFY_EXTERNAL_SSL" "false"
  ensure_config_secret CHAT_AI_DELEGATION_SECRET 32 || return 1
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
  upgrade_config
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

function cleanup_failed_upgrade() {
  local status=$?

  if [[ "${status}" != "0" && "${UPGRADE_COMMITTED}" != "1" ]]; then
    if [[ "${UPGRADE_CONFIG_CHANGED}" == "1" && \
      "${UPGRADE_DATABASE_MIGRATION_STARTED}" == "0" && \
      -f "${backup_config_file:-}" ]]; then
      if cp "${backup_config_file}" "${CONFIG_FILE}"; then
        gen_safe_config >/dev/null
        log_warn "Upgrade failed before database migration; restored ${CONFIG_FILE}"
      else
        log_error "Upgrade failed and ${CONFIG_FILE} could not be restored from ${backup_config_file}"
      fi
    elif [[ "${UPGRADE_DATABASE_MIGRATION_STARTED}" == "1" ]]; then
      log_warn "Upgrade stopped after database migration began; keep the upgraded configuration and retry the upgrade"
      log_warn "Pre-upgrade configuration backup: ${backup_config_file:-unknown}"
    fi
  fi

  trap - EXIT
  exit "${status}"
}

function backup_db() {
  if [[ "${SKIP_BACKUP_DB}" != "1" ]]; then
    if ! bash "${SCRIPT_DIR}/5_db_backup.sh"; then
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
      bash ./jmsctl.sh stop
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
  trap cleanup_failed_upgrade EXIT

  echo_yellow "\n3. $(gettext 'Backup database')"
  backup_db

  echo_yellow "\n4. $(gettext 'Loading Docker Image')"
  if ! bash "${BASE_DIR}/3_load_images.sh"; then
    log_error "$(gettext 'Failed to load Docker images')"
    exit 1
  fi

  echo_yellow "\n5. $(gettext 'Update Configuration File')"
  UPGRADE_CONFIG_CHANGED=1
  update_config_if_need
  configure_jdmc || {
    log_error "Failed to configure JDMC"
    exit 1
  }

  echo_yellow "\n6. $(gettext 'Apply database changes')"
  echo "$(gettext 'Changing database schema may take a while, please wait patiently')"
  UPGRADE_DATABASE_MIGRATION_STARTED=1
  db_migrations

  echo_yellow "\n7. $(gettext 'Upgrade Docker')"
  upgrade_docker
  upgrade_compose
  ensure_core_data_symlink || log_warn "Failed to prepare host core data symlink, continue upgrade"
  ensure_current_installer_link || {
    log_error "Failed to update /opt/current/installer"
    exit 1
  }
  upgrade_jdmc || {
    log_error "Failed to upgrade JDMC"
    exit 1
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
