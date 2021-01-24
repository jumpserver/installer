##　卸载脚本
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR=$(dirname ${BASE_DIR})

. "${BASE_DIR}/utils.sh"

function remove_jumpserver() {
  echo -e "请确认已经备份好相关数据, 此操作不可逆 ! \n"
  VOLUME_DIR=$(get_config VOLUME_DIR)
  confirm="n"
  read_from_input confirm "确认清理 JumpServer 相关文件?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    if [[ -f "${CONFIG_FILE}" ]]; then
      cd "${PROJECT_DIR}"
      bash ./jmsctl.sh down
      sleep 2s
      echo
      echo -e "正在清理 ${VOLUME_DIR}"
      rm -rf ${VOLUME_DIR}
      echo -e "正在清理 ${CONFIG_DIR}"
      rm -rf ${CONFIG_DIR}
      echo_done
    fi
  fi
  echo
  confirm="n"
  read_from_input confirm "是否清理 Docker 镜像?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    images=(
      "jumpserver/redis:6-alpine"
      "jumpserver/mysql:5"
      "jumpserver/nginx:alpine2"
      "jumpserver/luna:${VERSION}"
      "jumpserver/core:${VERSION}"
      "jumpserver/koko:${VERSION}"
      "jumpserver/guacamole:${VERSION}"
      "jumpserver/lina:${VERSION}"
    )
    for image in "${images[@]}"; do
      docker rmi ${image}
    done
  fi
  echo_green "清理完成 !"
}

function main() {
  echo_yellow "\n>>> 卸载 JumpServer"
  remove_jumpserver
}

main
