#!/usr/bin/env bash
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

target=$1

function upgrade_config() {
  # 如果配置文件有更新, 则添加到新的配置文件
  if docker ps -a | grep jms_guacamole >/dev/null; then
    docker stop jms_guacamole >/dev/null
    docker rm jms_guacamole >/dev/null
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
  if [[ "${image_files}" =~ xpack ]]; then
    set_config "USE_XPACK" 1
  fi
}

function update_config_if_need() {
  migrate_coco_to_koko_v1_54_to_v1_55
  migrate_config_v1_5_to_v2_0
  migrate_config_v2_5_v2_6
  upgrade_config
  echo_done
}

function backup_db() {
  project_name=$(get_config COMPOSE_PROJECT_NAME)
  net_name="${project_name}_net"
  if ! docker network ls | grep "${net_name}" >/dev/null; then
    check_container_if_need
  fi

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
  if docker ps | grep jumpserver >/dev/null; then
    confirm="n"
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
  else
    use_external_redis=$(get_config USE_EXTERNAL_REDIS)
    if [[ "${use_external_redis}" == "1" ]]; then
      cd "${PROJECT_DIR}" || exit 1
      bash ./jmsctl.sh stop jms_redis >/dev/null 2>&1
    fi
    echo_done
  fi
}

function clear_images() {
  if [[ "${current_version}" != "${to_version}" ]]; then
    confirm="n"
    read_from_input confirm "$(gettext 'Do you need to clean up the old version image')?" "y/n" "${confirm}"
    if [[ "${confirm}" != "y" ]]; then
      exit 1
    else
      docker images | grep "jumpserver/" | grep "${current_version}" | awk '{print $3}' | xargs docker rmi -f
      echo
    fi
  fi
  echo_done
}

function main() {
  confirm="n"
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

  echo_yellow "\n4. $(gettext 'Loading Docker Image')"
  bash "${BASE_DIR}/3_load_images.sh"

  echo_yellow "\n5. $(gettext 'Backup database')"
  backup_db

  echo_yellow "\n6. $(gettext 'Apply database changes')"
  echo "$(gettext 'Changing database schema may take a while, please wait patiently')"
  db_migrations

  echo_yellow "\n7. $(gettext 'Cleanup Image')"
  clear_images

  echo_yellow "\n8. $(gettext 'Upgrade successfully. You can now restart the program')"
  echo "./jmsctl.sh start"
  echo -e "\n"
  set_current_version
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
