#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

target=$1

function upgrade_config() {
  # 如果配置文件有更新, 则添加到新的配置文件
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
  rdp_port=$(get_config RDP_PORT)
  if [[ -z "${rdp_port}" ]]; then
    RDP_PORT=3389
    set_config RDP_PORT "${RDP_PORT}"
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
    SERVER_HOSTNAME='${HOSTNAME}'
    set_config SERVER_HOSTNAME "${SERVER_HOSTNAME}"
  fi
  # 字体平滑
  font_smoothing=$(get_config JUMPSERVER_ENABLE_FONT_SMOOTHING)
  if [ -z "${font_smoothing}" ]; then
    set_config JUMPSERVER_ENABLE_FONT_SMOOTHING "true"
  fi
  if grep -q "server nginx" "${CONFIG_DIR}/nginx/lb_http_server.conf"; then
    sedi "s/server nginx/server web/g" "${CONFIG_DIR}/nginx/lb_http_server.conf"
  fi
  if grep -q "sticky name=jms_route;" "${CONFIG_DIR}/nginx/lb_http_server.conf"; then
    sedi "s/sticky name=jms_route;/ip_hash;/g" "${CONFIG_DIR}/nginx/lb_http_server.conf"
  fi
  # MAGNUS 数据库
  magnus_mysql_port=$(get_config MAGNUS_MYSQL_PORT)
  if [ -z "${magnus_mysql_port}" ]; then
    MAGNUS_MYSQL_PORT=33060
    set_config MAGNUS_MYSQL_PORT "${MAGNUS_MYSQL_PORT}"
  fi
  magnus_mariadb_port=$(get_config MAGNUS_MARIADB_PORT)
  if [ -z "${magnus_mariadb_port}" ]; then
    MAGNUS_MARIADB_PORT=33061
    set_config MAGNUS_MARIADB_PORT "${MAGNUS_MARIADB_PORT}"
  fi
  magnus_postgre_port=$(get_config MAGNUS_POSTGRE_PORT)
  if [ -z "${magnus_postgre_port}" ]; then
    MAGNUS_POSTGRE_PORT=54320
    set_config MAGNUS_POSTGRE_PORT "${MAGNUS_POSTGRE_PORT}"
  fi
}

function migrate_coco_to_koko_v1_54_to_v1_55() {
  volume_dir=$(get_config VOLUME_DIR)
  coco_dir="${volume_dir}/coco"
  koko_dir="${volume_dir}/koko"
  if [[ ! -d "${koko_dir}" && -d "${coco_dir}" ]]; then
    mv "${coco_dir}" "${koko_dir}"
    ln -s "${koko_dir}" "${coco_dir}"
  fi
}

function migrate_config_v1_5_to_v2_0() {
  mkdir -p "${CONFIG_DIR}"

  # v1.5 => v2.0
  # 原先配置文件都在自己的目录，以后配置文件统一放在 /opt/jumpserver/config 中
  if [[ -f config.txt && ! -f ${CONFIG_FILE} ]]; then
    mv config.txt "${CONFIG_FILE}"
    rm -f .env
    ln -s "${CONFIG_FILE}" .env
    ln -s "${CONFIG_FILE}" config.link
  fi

  if [[ -f config.txt ]]; then
    mv config.txt config.txt."$(date '+%s')"
  fi
}

function migrate_config_v2_5_v2_6() {
  prepare_config

  # 处理之前版本没有 USE_XPACK 的问题
  image_files=""
  if [[ -d "$BASE_DIR/images" ]]; then
    image_files=$(ls "$BASE_DIR"/images)
  fi
  if [[ "${image_files}" =~ omnidb ]]; then
    set_config "USE_XPACK" 1
  fi
}

function update_config_if_need() {
  migrate_coco_to_koko_v1_54_to_v1_55
  migrate_config_v1_5_to_v2_0
  migrate_config_v2_5_v2_6
  upgrade_config
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
    sedi "s@VERSION=.*@VERSION=${to_version}@g" "${PROJECT_DIR}/static.env"
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

  echo_yellow "\n7. $(gettext 'Upgrade successfully. You can now restart the program')"
  echo "cd ${PROJECT_DIR}"
  echo "./jmsctl.sh start"
  echo -e "\n"
  set_current_version
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
