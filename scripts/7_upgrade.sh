#!/usr/bin/env bash
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./util.sh
source "${BASE_DIR}/utils.sh"
# shellcheck source=./2_install_docker.sh
source "${BASE_DIR}/2_install_docker.sh"

target=$1

function migrate_coco_to_koko_v1_54_to_v1_55() {
  volume_dir=$(get_config VOLUME_DIR)
  coco_dir="${volume_dir}/coco"
  koko_dir="${volume_dir}/koko"
  if [[ ! -d "${koko_dir}" && -d "${coco_dir}" ]]; then
    mv ${coco_dir} ${koko_dir}
    ln -s ${koko_dir} ${coco_dir}
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
  # 迁移配置文件过去
  configs=("nginx" "core" "koko" "mysql" "redis")
  for c in "${configs[@]}";do
    if [[ ! -e ${CONFIG_DIR}/$c ]];then
      cp -R "${PROJECT_DIR}/config_init/$c" "${CONFIG_DIR}"
    fi
  done

  # 处理之前版本没有 USE_XPACK 的问题
  image_files=""
  if [[ -d "$BASE_DIR/images" ]];then
    image_files=$(ls "$BASE_DIR"/images)
  fi
  if [[ "${image_files}" =~ xpack ]];then
    set_config "USE_XPACK" 1
  fi

  # 处理一下之前 lb_http_server 配置文件没有迁移的问题
  if [[ ! -f "${CONFIG_DIR}/nginx/lb_http_server.conf" ]];then
    cp -R "${PROJECT_DIR}"/config_init/nginx/*.conf "${CONFIG_DIR}"/nginx
  fi
}


function update_config_if_need() {
  migrate_coco_to_koko_v1_54_to_v1_55
  migrate_config_v1_5_to_v2_0
  migrate_config_v2_5_v2_6
}

function update_proc_if_need() {
  install_docker
}

function backup_db() {
  if [[ "${SKIP_BACKUP_DB}" != "1" ]]; then
    if ! bash "${SCRIPT_DIR}/5_db_backup.sh"; then
      confirm="n"
      read_from_input confirm "备份数据库失败, 继续升级吗?" "y/n" "${confirm}"
      if [[ "${confirm}" == "n" ]]; then
        exit 1
      fi
    fi
  else
    echo "SKIP_BACKUP_DB=${SKIP_BACKUP_DB}, 跳过备份数据库"
  fi
}

function main() {
  confirm="n"
  to_version="${VERSION}"
  if [[ -n "${target}" ]];then
    to_version="${target}"
  fi

  read_from_input confirm "你确定要升级到 ${to_version} 版本吗?" "y/n" "${confirm}"
  if [[ "${confirm}" != "y" || -z "${to_version}" ]];then
    exit 3
  fi

  if [[ -n "${target}" && ${target} != "${VERSION}" ]];then
    sed -i "s@VERSION=${VERSION}@VERSION=${target}@g" "${PROJECT_DIR}/static.env"
    export VERSION=${target}
  fi

  echo_yellow "1. 备份数据库"
  backup_db || exit 2

  echo_yellow "\n2. 检查配置变更"
  update_config_if_need && echo_done || (echo_failed; exit  3)

  echo_yellow "\n3. 检查程序文件变更"
  update_proc_if_need || (echo_failed; exit  4)

  echo_yellow "\n4. 升级镜像文件"
  bash "${SCRIPT_DIR}/3_load_images.sh" && echo_done || (echo_failed; exit  5)

  echo_yellow "\n5. 进行数据库变更"
  echo "表结构变更可能需要一段时间，请耐心等待"
  perform_db_migrations && echo_done || (echo_failed; exit 6)

  echo_yellow "\n6. 升级成功, 可以启动程序了"
  echo -e "\n\n"
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  echo_logo
  main
fi
