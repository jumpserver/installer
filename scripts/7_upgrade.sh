#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"
. "${BASE_DIR}/2_install_docker.sh"

target=$1

function check_and_set_config() {
  local config_key=$1
  local default_value=$2
  local current_value=$(get_config ${config_key})
  if [ -z "${current_value}" ]; then
    set_config ${config_key} "${default_value}"
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
  local containers=("jms_guacamole" "jms_lina" "jms_luna" "jms_nginx" "jms_xpack" "jms_lb" "jms_omnidb" "jms_kael" "jms_magnus")
  for container in "${containers[@]}"; do
    if docker ps -a | grep ${container} &>/dev/null; then
      docker stop ${container} &>/dev/null
      docker rm ${container} &>/dev/null
    fi
  done
  if docker ps -a | grep jms_xpack &>/dev/null; then
    docker volume rm jms_share-volume &>/dev/null
  fi
  check_and_set_config "CURRENT_VERSION" "${VERSION}"
  check_and_set_config "CLIENT_MAX_BODY_SIZE" "4096m"
  check_and_set_config "SERVER_HOSTNAME" "${HOSTNAME}"
  check_and_set_config "JUMPSERVER_ENABLE_FONT_SMOOTHING" "true"
  check_and_set_config "USE_LB" "1"
  # XPACK
  use_xpack=$(get_config_or_env USE_XPACK)
  if [[ "${use_xpack}" == "1" ]]; then
    check_and_set_config "RDP_PORT" "3389"
    check_and_set_config "XRDP_PORT" "3390"
    check_and_set_config "MAGNUS_MYSQL_PORT" "33061"
    check_and_set_config "MAGNUS_MARIADB_PORT" "33062"
    check_and_set_config "MAGNUS_REDIS_PORT" "63790"
    check_and_set_config "MAGNUS_POSTGRESQL_PORT" "54320"
    check_and_set_config "MAGNUS_SQLSERVER_PORT" "14330"
    check_and_set_config "MAGNUS_ORACLE_PORTS" "30000-30030"
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
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -d "${volume_dir}/core/logs" ]] && [[ ! -d "${volume_dir}/core/data/logs" ]]; then
    mv "${volume_dir}/core/logs" "${volume_dir}/core/data/logs"
  fi
}

function migrate_config() {
  prepare_config
}

function update_config_if_need() {
  migrate_config_v1_5_to_v2_0
  migrate_config_v2_0_to_v3_0
  migrate_coco_to_koko
  migrate_config
  upgrade_config
  clean_file
}

function backup_config() {
  VOLUME_DIR=$(get_config VOLUME_DIR)
  BACKUP_DIR="${VOLUME_DIR}/db_backup"
  CURRENT_VERSION=$(get_config CURRENT_VERSION)
  backup_config_file="${BACKUP_DIR}/config-${CURRENT_VERSION}-$(date +%F_%T).conf"
  if [[ ! -d ${BACKUP_DIR} ]]; then
    mkdir -p ${BACKUP_DIR}
  fi
  cp "${CONFIG_FILE}" "${backup_config_file}"
  echo "$(gettext 'Back up to') ${backup_config_file}"
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
  if docker ps | grep -E "core|koko|lion"&>/dev/null; then
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
  migrate_data_folder
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
  if [[ "${current_version}" != "${to_version}" ]]; then
    old_images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "jumpserver/" | grep "${current_version}")
    if [[ -n "${old_images}" ]]; then
      confirm="y"
      read_from_input confirm "$(gettext 'Do you need to clean up the old version image')?" "y/n" "${confirm}"
      if [[ "${confirm}" == "y" ]]; then
        echo "${old_images}" | xargs docker rmi -f
      fi
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
  confirm="y"
  to_version="${VERSION}"
  if [[ -n "${target}" ]]; then
    to_version="${target}"
  fi

  read_from_input confirm "$(gettext 'Are you sure you want to update the current version to') ${to_version} ?" "y/n" "${confirm}"
  if [[ "${confirm}" != "y" || -z "${to_version}" ]]; then
    exit 3
  fi

  if [[ "${to_version}" && "${to_version}" != "${VERSION}" ]]; then
    sed -i "s@VERSION=.*@VERSION=${to_version}@g" "${PROJECT_DIR}/static.env"
    export VERSION=${to_version}
  fi
  echo
  update_config_if_need
  echo
  check_compose_install

  echo_yellow "\n2. $(gettext 'Loading Docker Image')"
  bash "${BASE_DIR}/3_load_images.sh"

  echo_yellow "\n3. $(gettext 'Backup database')"
  backup_db

  echo_yellow "\n4. $(gettext 'Backup Configuration File')"
  backup_config

  echo_yellow "\n5. $(gettext 'Apply database changes')"
  echo "$(gettext 'Changing database schema may take a while, please wait patiently')"
  db_migrations

  echo_yellow "\n6. $(gettext 'Cleanup Image')"
  clean_images

  echo_yellow "\n7. $(gettext 'Upgrade Docker')"
  upgrade_docker
  upgrade_compose

  installation_log "upgrade"

  echo_yellow "\n8. $(gettext 'Upgrade successfully. You can now restart the program')"
  echo "cd ${PROJECT_DIR}"
  echo "./jmsctl.sh start"
  echo -e "\n"
  set_current_version
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
