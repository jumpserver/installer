#!/bin/bash

source /etc/profile
BASE_DIR=$(dirname "$0")
# shellcheck source=./util.sh
. "${BASE_DIR}/utils.sh"

DOCKER_MD5=8c4a1d65ddcecf91ae357b434dffe039
DOCKER_COMPOSE_MD5=7f508b543123e8c81ca138d5b36001a2
IMAGE_DIR="images"

DOCKER_IMAGE_PREFIX="${DOCKER_IMAGE_PREFIX-}"
USE_XPACK="${USE_XPACK-0}"

function prepare_docker_bin() {
  if [[ ! -f /tmp/docker.tar.gz || $(check_md5 /tmp/docker.tar.gz ${DOCKER_MD5}) ]]; then
    echo "开始下载 Docker 程序 ..."
    wget "${DOCKER_BIN_URL}" -O /tmp/docker.tar.gz
  fi
  cp /tmp/docker.tar.gz . && tar xzf docker.tar.gz && rm -f docker.tar.gz

  if [[ ! -f /tmp/docker-compose || $(check_md5 /tmp/docker-compose ${DOCKER_COMPOSE_MD5}) ]]; then
    echo "开始下载 Docker compose 程序 ..."
    wget "${DOCKER_COMPOSE_BIN_URL}" -O /tmp/docker-compose
  fi
  cp /tmp/docker-compose docker/
}

function prepare_image_files() {
  scope="public"
  if [[ "${USE_XPACK}" == "1" ]]; then
    scope="all"
  fi
  images=$(get_images $scope)
  for image in ${images}; do
    echo ""
    if [[ -n "${DOCKER_IMAGE_PREFIX}" ]]; then
      docker pull "${DOCKER_IMAGE_PREFIX}/${image}"
      docker tag "${DOCKER_IMAGE_PREFIX}/${image}" "${image}"
    else
      docker pull "${image}"
    fi
    filename=$(basename "${image}").tar
    component=$(echo "${filename}" | awk -F: '{ print $1 }')
    md5_filename=$(basename "${image}").md5
    md5_path=${IMAGE_DIR}/${md5_filename}

    image_id=$(docker inspect -f "{{.ID}}" ${image})
    saved_id=""
    if [[ -f "${md5_path}" ]]; then
      saved_id=$(cat "${md5_path}")
    fi

    mkdir -p "${IMAGE_DIR}"
    if [[ ${image_id} != "${saved_id}" ]]; then
      rm -f ${IMAGE_DIR}/${component}*
      docker save -o "${IMAGE_DIR}/${filename}" "${image}" && echo "${image_id}" >"${md5_path}"
    else
      echo "已加载过该镜像, 跳过: ${image}"
    fi
  done

}

function prepare() {
  prepare_docker_bin
  prepare_image_files
}
