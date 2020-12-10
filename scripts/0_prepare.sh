#!/bin/bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./util.sh
. "${BASE_DIR}/utils.sh"

IMAGE_DIR="images"
DOCKER_IMAGE_PREFIX="${DOCKER_IMAGE_PREFIX-}"
USE_XPACK="${USE_XPACK-0}"

function prepare_config() {
  if [[ "${USE_XPACK}" == "1" ]]; then
    sed -i 's@USE_XPACK=.*@USE_XPACK=1@g' "${PROJECT_DIR}"/config-example.txt
  fi
}

function prepare_docker_bin() {
  md5_matched=$(check_md5 /tmp/docker.tar.gz "${DOCKER_MD5}")
  if [[ ! -f /tmp/docker.tar.gz || "${md5_matched}" != "1" ]]; then
    prepare_online_install_required_pkg
    get_file_md5 /tmp/docker.tar.gz
    echo "开始下载 Docker 程序 ..."
    wget "${DOCKER_BIN_URL}" -O /tmp/docker.tar.gz
  else
    echo "使用 Docker 缓存文件: /tmp/docker.tar.gz"
  fi
  cp /tmp/docker.tar.gz . && tar xzf docker.tar.gz && rm -f docker.tar.gz

  md5_matched=$(check_md5 /tmp/docker-compose "${DOCKER_COMPOSE_MD5}")
  if [[ ! -f /tmp/docker-compose || "${md5_matched}" != "1" ]]; then
    echo "开始下载 Docker compose 程序 ..."
    wget "${DOCKER_COMPOSE_BIN_URL}" -O /tmp/docker-compose
  else
    echo "使用 Docker compose 缓存文件: /tmp/docker-compose"
  fi
  cp /tmp/docker-compose docker/
  chmod +x docker/*
  export PATH=$PATH:$(pwd)/docker
}

function prepare_image_files() {
  if ! pgrep -f "docker" > /dev/null; then
    echo "Docker 没有运行, 请安装并启动"
    exit 1
  fi

  scope="public"
  if [[ "${USE_XPACK}" == "1" ]]; then
    scope="all"
  fi
  images=$(get_images $scope)
  i=0
  for image in ${images}; do
    ((i++)) || true
    echo "[${image}]"
    if [[ -n "${DOCKER_IMAGE_PREFIX}" && $(image_has_prefix "${image}") == "0" ]]; then
      docker pull "${DOCKER_IMAGE_PREFIX}/${image}"
      docker tag "${DOCKER_IMAGE_PREFIX}/${image}" "${image}"
    else
      docker pull "${image}"
    fi
    filename=$(basename "${image}").tar
    component=$(echo "${filename}" | awk -F: '{ print $1 }')
    md5_filename=$(basename "${image}").md5
    md5_path=${IMAGE_DIR}/${md5_filename}

    image_id=$(docker inspect -f "{{.ID}}" "${image}")
    saved_id=""
    if [[ -f "${md5_path}" ]]; then
      saved_id=$(cat "${md5_path}")
    fi

    mkdir -p "${IMAGE_DIR}"
    # 这里达不到想要的想过，因为在构建前会删掉目录下的所有文件，所以 save_id 不可能存在
    if [[ ${image_id} != "${saved_id}" ]]; then
      rm -f ${IMAGE_DIR}/${component}*
      image_path="${IMAGE_DIR}/${filename}"
      echo "保存镜像 ${image} -> ${image_path}"
      docker save -o "${image_path}" "${image}" && echo "${image_id}" >"${md5_path}"
    else
      echo "已加载过该镜像, 跳过: ${image}"
    fi
    echo
  done

}


function main() {
  prepare_online_install_required_pkg
  prepare_config

  echo "1. 准备 Docker 离线包"
  prepare_docker_bin

  echo -e "\n2. 准备镜像离线包"
  prepare_image_files

}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
