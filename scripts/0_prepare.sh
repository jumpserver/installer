#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

IMAGE_DIR="${BASE_DIR}/images"

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
  tar -xf /tmp/docker.tar.gz -C "${BASE_DIR}/" || {
    rm -rf "${BASE_DIR}/docker" /tmp/docker.tar.gz
    exit 1
  }
  chown -R root:root "${BASE_DIR}/docker"
  chmod +x ${BASE_DIR}/docker/*
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
  if [[ ! -d "${BASE_DIR}/docker" ]]; then
    mkdir -p "${BASE_DIR}/docker"
  fi
  \cp -f /tmp/docker-compose "${BASE_DIR}/docker/"
  chown -R root:root "${BASE_DIR}/docker/docker-compose"
  chmod +x "${BASE_DIR}/docker/docker-compose"
}

function prepare_image_files() {
  if ! pgrep -f "docker"&>/dev/null; then
    echo "$(gettext 'Docker is not running, please install and start') ..."
    exit 1
  fi
  pull_images

  images=$(get_images)
  for image in ${images}; do
    filename=$(basename "${image}").zst
    image_path="${IMAGE_DIR}/${filename}"
    md5_filename=$(basename "${image}").md5
    md5_path="${IMAGE_DIR}/${md5_filename}"

    image_id=$(docker inspect -f "{{.ID}}" "${image}")
    saved_id=""
    if [[ -f "${md5_path}" ]]; then
      saved_id=$(cat "${md5_path}")
    fi

    if [[ ! -d "${IMAGE_DIR}" ]]; then
      mkdir -p "${IMAGE_DIR}"
    fi

    if [[ -f "${image_path}" ]]; then
      if [[ "${image_id}" != "${saved_id}" ]]; then
        rm -f "${image_path}" "${md5_path}"
      else
        echo "$(gettext 'The image has been saved, skipping'): ${image}"
        continue
      fi
    fi
    echo "$(gettext 'Save image') ${image} -> ${image_path}"
    # docker save -o "${image_path}" "${image}" &
    docker save "${image}" | zstd -f -q -o "${image_path}" &
    echo "${image_id}" >"${md5_path}" &
  done
  wait
}

function main() {
  prepare_check_required_pkg

  echo "$(gettext 'Preparing Docker offline package')"
  prepare_docker_bin
  prepare_compose_bin

  echo -e "\n$(gettext 'Preparing image offline package')"
  prepare_image_files
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi