#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

IMAGE_DIR="images"
USE_XPACK="${USE_XPACK-0}"

function prepare_config_xpack() {
  if [[ "${USE_XPACK}" == "1" ]]; then
    sed -i 's@^USE_XPACK=.*@USE_XPACK=1@g' "${PROJECT_DIR}"/config-example.txt
  fi
}

function prepare_docker_bin() {
  md5_matched=$(check_md5 /tmp/docker.tar.gz "${DOCKER_MD5}")
  if [[ ! -f /tmp/docker.tar.gz || "${md5_matched}" != "1" ]]; then
    prepare_check_required_pkg
    get_file_md5 /tmp/docker.tar.gz
    echo "$(gettext 'Starting to download Docker engine') ..."
    wget -q "${DOCKER_BIN_URL}" -O /tmp/docker.tar.gz || {
      log_error "$(gettext 'Download docker fails, check the network is normal')"
      rm -f /tmp/docker.tar.gz
      exit 1
    }
  else
    echo "$(gettext 'Using Docker cache'): /tmp/docker.tar.gz"
  fi
  tar -xf /tmp/docker.tar.gz -C ./ || {
    rm -rf docker /tmp/docker.tar.gz
    exit 1
  }
  chown -R root:root docker
  chmod +x docker/*
}

function prepare_compose_bin() {
  md5_matched=$(check_md5 /tmp/docker-compose "${DOCKER_COMPOSE_MD5}")
  if [[ ! -f /tmp/docker-compose || "${md5_matched}" != "1" ]]; then
    prepare_check_required_pkg
    get_file_md5 /tmp/docker-compose
    echo "$(gettext 'Starting to download Docker Compose binary') ..."
    wget -q "${DOCKER_COMPOSE_BIN_URL}" -O /tmp/docker-compose || {
      log_error "$(gettext 'Download docker-compose fails, check the network is normal')"
      rm -f /tmp/docker-compose
      exit 1
    }
  else
    echo "$(gettext 'Using Docker Compose cache'): /tmp/docker-compose"
  fi
  if [[ ! -d "$BASE_DIR/docker" ]]; then
    mkdir -p "${BASE_DIR}/docker"
  fi
  \cp -rf /tmp/docker-compose docker/
  chown -R root:root docker
  chmod +x docker/*
  export PATH=$PATH:$(pwd)/docker
}

function prepare_image_files() {
  if ! pgrep -f "docker" >/dev/null; then
    echo "$(gettext 'Docker is not running, please install and start') ..."
    exit 1
  fi

  images=$(get_images)
  if ! echo ${images} | grep -q 'jumpserver/mysql:5.7'; then
    images+=' jumpserver/mysql:5.7'
  fi

  for image in ${images}; do
    echo "[${image}]"
    pull_image "$image"

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
  prepare_check_required_pkg
  prepare_config_xpack

  echo " $(gettext 'Preparing Docker offline package')"
  prepare_docker_bin
  prepare_compose_bin

  echo -e "\n $(gettext 'Preparing image offline package')"
  prepare_image_files
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
