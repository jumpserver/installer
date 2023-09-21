#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"
. "${BASE_DIR}/2_install_docker.sh"

target=$1

function upgrade_config() {
  # 如果配置文件有更新, 则添加到新的配置文件
  check_docker_start
  if docker ps -a | grep jms_guacamole &>/dev/null; then
    docker stop jms_guacamole &>/dev/null
    docker rm jms_guacamole &>/dev/null
  fi
  if docker ps -a | grep jms_lina &>/dev/null; then
    docker stop jms_lina &>/dev/null
    docker rm jms_lina &>/dev/null
  fi
  if docker ps -a | grep jms_luna &>/dev/null; then
    docker stop jms_luna &>/dev/null
    docker rm jms_luna &>/dev/null
  fi
  if docker ps -a | grep jms_nginx &>/dev/null; then
    docker stop jms_nginx &>/dev/null
    docker rm jms_nginx &>/dev/null
  fi
  if docker ps -a | grep jms_xpack &>/dev/null; then
    docker stop jms_xpack &>/dev/null
    docker rm jms_xpack &>/dev/null
    docker volume rm jms_share-volume &>/dev/null
  fi
  if docker ps -a | grep jms_xrdp &>/dev/null; then
    docker stop jms_xrdp &>/dev/null
    docker rm jms_xrdp &>/dev/null
  fi
  if docker ps -a | grep jms_lb &>/dev/null; then
    docker stop jms_lb &>/dev/null
    docker rm jms_lb &>/dev/null
  fi
  if docker ps -a | grep jms_omnidb &>/dev/null; then
    docker stop jms_omnidb &>/dev/null
    docker rm jms_omnidb &>/dev/null
  fi
  current_version=$(get_config CURRENT_VERSION)
  if [ -z "${current_version}" ]; then
    set_config CURRENT_VERSION "${VERSION}"
  fi
  client_max_body_size=$(get_config CLIENT_MAX_BODY_SIZE)
  if [ -z "${client_max_body_size}" ]; then
    CLIENT_MAX_BODY_SIZE=4096m
    set_config CLIENT_MAX_BODY_SIZE "${CLIENT_MAX_BODY_SIZE}"
  fi
  server_hostname=$(get_config SERVER_HOSTNAME)
  if [ -z "${server_hostname}" ]; then
    SERVER_HOSTNAME="${HOSTNAME}"
    set_config SERVER_HOSTNAME "${SERVER_HOSTNAME}"
  fi
  # 字体平滑
  font_smoothing=$(get_config JUMPSERVER_ENABLE_FONT_SMOOTHING)
  if [ -z "${font_smoothing}" ]; then
    set_config JUMPSERVER_ENABLE_FONT_SMOOTHING "true"
  fi
  if grep -q "server nginx" "${CONFIG_DIR}/nginx/lb_http_server.conf"; then
    sed -i "s/server nginx/server web/g" "${CONFIG_DIR}/nginx/lb_http_server.conf"
  fi
  if grep -q "sticky name=jms_route;" "${CONFIG_DIR}/nginx/lb_http_server.conf"; then
    sed -i "s/sticky name=jms_route;/ip_hash;/g" "${CONFIG_DIR}/nginx/lb_http_server.conf"
  fi
  # MAGNUS 数据库
  magnus_ports=$(get_config MAGNUS_PORTS)
  if [ -n "${magnus_ports}" ]; then
    sed -i "s/MAGNUS_PORTS/MAGNUS_ORACLE_PORTS/g" ${CONFIG_FILE}
  fi
  magnus_mysql_port=$(get_config MAGNUS_MYSQL_PORT)
  if [ -z "${magnus_mysql_port}" ]; then
    MAGNUS_MYSQL_PORT=33061
    set_config MAGNUS_MYSQL_PORT "${MAGNUS_MYSQL_PORT}"
  fi
  magnus_mariadb_port=$(get_config MAGNUS_MARIADB_PORT)
  if [ -z "${magnus_mariadb_port}" ]; then
    MAGNUS_MARIADB_PORT=33062
    set_config MAGNUS_MARIADB_PORT "${MAGNUS_MARIADB_PORT}"
  fi
  magnus_redis_port=$(get_config MAGNUS_REDIS_PORT)
  if [ -z "${magnus_redis_port}" ]; then
    MAGNUS_REDIS_PORT=63790
    set_config MAGNUS_REDIS_PORT "${MAGNUS_REDIS_PORT}"
  fi
  # XPACK
  use_xpack=$(get_config_or_env USE_XPACK)
  if [[ "${use_xpack}" == "1" ]]; then
    rdp_port=$(get_config RDP_PORT)
    if [[ -z "${rdp_port}" ]]; then
      RDP_PORT=3389
      set_config RDP_PORT "${RDP_PORT}"
    fi
    magnus_postgresql_port=$(get_config MAGNUS_POSTGRESQL_PORT)
    if [ -z "${magnus_postgresql_port}" ]; then
      MAGNUS_POSTGRESQL_PORT=54320
      set_config MAGNUS_POSTGRESQL_PORT "${MAGNUS_POSTGRESQL_PORT}"
    fi
    magnus_oracle_ports=$(get_config MAGNUS_ORACLE_PORTS)
    if [ -z "${magnus_oracle_ports}" ]; then
      MAGNUS_ORACLE_PORTS=30000-30030
      set_config MAGNUS_ORACLE_PORTS "${MAGNUS_ORACLE_PORTS}"
    fi
    xrdp_port=$(get_config XRDP_PORT)
    if [ -z "${xrdp_port}" ]; then
      XRDP_PORT=3390
      set_config XRDP_PORT "${XRDP_PORT}"
    fi
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
  if docker ps | grep -E "core|koko|lion" >/dev/null; then
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
    confirm="y"
    read_from_input confirm "$(gettext 'Do you need to clean up the old version image')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      echo
      docker images | grep "jumpserver/" | grep "${current_version}" | awk '{print $3}' | xargs docker rmi -f
    fi
  fi
}

function upgrade_docker() {
  if [[ -f "/usr/local/bin/docker" ]]; then
    if [[ ! "$(/usr/local/bin/docker -v | grep ${DOCKER_VERSION})" ]]; then
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
  if [[ -f "/usr/local/bin/docker-compose" ]]; then
    if [[ ! "$(/usr/local/bin/docker-compose version | grep ${DOCKER_COMPOSE_VERSION})" ]]; then
      echo
      echo -e "$(docker-compose version) \033[33m-->\033[0m Docker Compose version \033[32m${DOCKER_COMPOSE_VERSION}\033[0m"
      confirm="n"
      read_from_input confirm "$(gettext 'Do you need upgrade Docker Compose')?" "y/n" "${confirm}"
      if [[ "${confirm}" == "y" ]]; then
        echo
        cd "${BASE_DIR}" || exit 1
        install_compose
        check_compose_install
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
