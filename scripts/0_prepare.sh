#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

IMAGE_DIR="${BASE_DIR}/images"

function download_and_verify() {
  local url=$1
  local target_path=$2
  local md5_target_path="${target_path}.md5"

  prepare_check_required_pkg
  if [[ ! -f "${md5_target_path}" ]]; then
    echo "$(gettext 'Starting to download'): ${url}.md5"
    wget -q "${url}.md5" -O "${md5_target_path}" || {
      log_error "$(gettext 'Download fails, check the network is normal')"
      rm -f "${md5_target_path}"
      exit 1
    }
  else
    echo "$(gettext 'Using cache'): ${md5_target_path}"
  fi

  local expected_md5=$(cut -d ' ' -f1 "${md5_target_path}")
  local md5_matched=$(check_md5 "${target_path}" "${expected_md5}")
  if [[ ! -f "${target_path}" || "${md5_matched}" != "1" ]]; then
    echo "$(gettext 'Starting to download'): ${url}"
    wget -q "${url}" -O "${target_path}" || {
      log_error "$(gettext 'Download fails, check the network is normal')"
      rm -f "${target_path}" "${md5_target_path}"
      exit 1
    }
  else
    echo "$(gettext 'Using cache'): ${target_path}"
  fi
}

function prepare_docker_bin() {
  download_and_verify "${DOCKER_BIN_URL}" "${BASE_DIR}/docker/docker.tar.gz"
}

function prepare_compose_bin() {
  download_and_verify "${DOCKER_COMPOSE_BIN_URL}" "${BASE_DIR}/docker/docker-compose"
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
    filename=$(basename "${image}").tar
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
    docker save -o "${image_path}" "${image}" &
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