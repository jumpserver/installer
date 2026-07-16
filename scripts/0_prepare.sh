#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

IMAGE_DIR="${BASE_DIR}/images"

function download() {
  local url=$1
  local target_path=$2

  parent_dir=$(dirname "${target_path}")
  if [[ ! -d "${parent_dir}" ]]; then
    mkdir -p "${parent_dir}"
  fi

  prepare_check_required_pkg
  if [[ ! -f "${target_path}" ]]; then
    echo "$(gettext 'Starting to download'): ${url}"
    wget --show-progress -q "${url}" -O "${target_path}" || {
      log_error "$(gettext 'Download fails, check the network is normal')"
      rm -f "${target_path}"
      exit 1
    }
  else
    echo "$(gettext 'Using cache'): ${target_path}"
  fi
}

function prepare_docker_bin() {
  download "${DOCKER_BIN_URL}" "${BASE_DIR}/docker/docker.tar.gz"
}

function prepare_compose_bin() {
  download "${COMPOSE_BIN_URL}" "${BASE_DIR}/docker/docker-compose"
  chown -R root:root "${BASE_DIR}/docker/docker-compose"
  chmod +x "${BASE_DIR}/docker/docker-compose"
}

function prepare_image_files() {
  if ! pgrep -f "docker"&>/dev/null; then
    echo "$(gettext 'Docker is not running, please install and start') ..."
    exit 1
  fi

  if [[ ! -d "${IMAGE_DIR}" ]]; then
    mkdir -p "${IMAGE_DIR}"
  fi
  rm -f "${IMAGE_DIR}"/*

  pull_images

  images=$(get_images)
  for image in ${images}; do
    app_name=$(basename "${image}")
    filename="${app_name}.zst"
    echo "${image}"
    
    image_path="${IMAGE_DIR}/${filename}"
    md5_filename=$(basename "${image}").md5
    md5_path="${IMAGE_DIR}/${md5_filename}"

    if ! image_id=$(docker image inspect -f "{{.ID}}" "${image}" 2>/dev/null); then
      log_error "$(gettext 'Image inspect failed'): ${image}"
      return 1
    fi
    saved_id=""
    if [[ -f "${md5_path}" ]]; then
      saved_id=$(cat "${md5_path}")
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
    docker save "${image}" | zstd -f -q -o "${image_path}" &
    echo "${image_id}" >"${md5_path}" &
  done
  wait
}

function main() {
  config_path='/opt/jumpserver/config/config.txt' 
  if [[ -f "${config_path}" ]];then
      mv "${config_path}" "${config_path}.bak"
  fi
  prepare_check_required_pkg

  gettext 'Preparing Docker offline package'
  echo
  time prepare_docker_bin
  time prepare_compose_bin

  gettext 'Preparing image offline package'
  echo
  time prepare_image_files
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
