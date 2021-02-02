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
    echo "$(gettext 'Starting to download Docker engine') ..."
    wget -q "${DOCKER_BIN_URL}" -O /tmp/docker.tar.gz || {
      log_error "下载 docker 失败, 请检查网络是否正常"
      exit 1
    }
  else
    echo "$(gettext 'Using Docker cache'): /tmp/docker.tar.gz"
  fi
  cp /tmp/docker.tar.gz . && tar xzf docker.tar.gz && rm -f docker.tar.gz
  chmod +x docker/*
}

function prepare_compose_bin() {
  md5_matched=$(check_md5 /tmp/docker-compose "${DOCKER_COMPOSE_MD5}")
  if [[ ! -f /tmp/docker-compose || "${md5_matched}" != "1" ]]; then
    echo "$(gettext 'Starting to download Docker Compose binary') ..."
    wget "${DOCKER_COMPOSE_BIN_URL}" -O /tmp/docker-compose
    prepare_online_install_required_pkg
    echo "$(gettext 'Starting to download Docker Compose binary') ..."
    wget -q "${DOCKER_COMPOSE_BIN_URL}" -O /tmp/docker-compose || {
      log_error "下载 docker-compose 失败, 请检查网络是否正常"
      exit 1
    }
  else
    echo "$(gettext 'Using Docker Compose cache'): /tmp/docker-compose"
  fi
  if [[ ! -d "$BASE_DIR/docker" ]]; then
    mkdir -p ${BASE_DIR}/docker
  fi
  cp /tmp/docker-compose docker/
  chmod +x docker/*
  export PATH=$PATH:$(pwd)/docker
}

function prepare_image_files() {
  if ! pgrep -f "docker" > /dev/null; then
    echo "$(gettext 'Docker is not running, please install and start')"
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
      echo "$(gettext 'Save image') ${image} -> ${image_path}"
      docker save -o "${image_path}" "${image}" && echo "${image_id}" >"${md5_path}"
    else
      echo "$(gettext 'The image has been saved, skipping'): ${image}"
    fi
    echo
  done

}


function main() {
  prepare_online_install_required_pkg
  prepare_config

  echo "1. $(gettext 'Preparing Docker offline package')"
  prepare_docker_bin
  prepare_compose_bin

  echo -e "\n2. $(gettext 'Preparing image offline package')"
  prepare_image_files

}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
