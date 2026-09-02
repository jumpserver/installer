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
    wget -q "${url}" -O "${target_path}" || {
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
  local images image app_name filename image_path sha256_filename sha256_path
  local image_id saved_id pid index
  local save_failed=0
  local -a save_images=() save_paths=() save_sha256_paths=() save_ids=() save_pids=()

  if ! pgrep -f "docker"&>/dev/null; then
    echo "$(gettext 'Docker is not running, please install and start') ..."
    return 1
  fi

  if [[ ! -d "${IMAGE_DIR}" ]]; then
    mkdir -p "${IMAGE_DIR}"
  fi
  rm -f "${IMAGE_DIR}"/*

  # The offline bundle must carry optional OpenBao even when it is disabled by
  # default, so it can be enabled later without registry access.
  local INCLUDE_OPENBAO_IMAGE=1
  export INCLUDE_OPENBAO_IMAGE

  if ! pull_images; then
    log_error "$(gettext 'Failed to pull Docker images')"
    return 1
  fi

  images=$(get_images)
  for image in ${images}; do
    app_name=$(basename "${image}")
    filename="${app_name}.zst"
    echo "${image}"
    
    image_path="${IMAGE_DIR}/${filename}"
    sha256_filename=$(basename "${image}").sha256
    sha256_path="${IMAGE_DIR}/${sha256_filename}"

    if ! image_id=$(docker image inspect -f "{{.ID}}" "${image}" 2>/dev/null); then
      log_error "$(gettext 'Image inspect failed'): ${image}"
      return 1
    fi
    saved_id=""
    if [[ -f "${sha256_path}" ]]; then
      saved_id=$(cat "${sha256_path}")
    fi

    if [[ -f "${image_path}" ]]; then
      if [[ "${image_id}" != "${saved_id}" ]]; then
        rm -f "${image_path}" "${sha256_path}"
      else
        echo "$(gettext 'The image has been saved, skipping'): ${image}"
        continue
      fi
    fi
    echo "$(gettext 'Save image') ${image} -> ${image_path}"
    save_images+=("${image}")
    save_paths+=("${image_path}")
    save_sha256_paths+=("${sha256_path}")
    save_ids+=("${image_id}")
  done

  for index in "${!save_images[@]}"; do
    (
      set -o pipefail
      if ! docker save "${save_images[${index}]}" | zstd -f -q -o "${save_paths[${index}]}"; then
        rm -f "${save_paths[${index}]}" "${save_sha256_paths[${index}]}"
        exit 1
      fi
      if ! printf '%s\n' "${save_ids[${index}]}" >"${save_sha256_paths[${index}]}"; then
        rm -f "${save_paths[${index}]}" "${save_sha256_paths[${index}]}"
        exit 1
      fi
    ) &
    save_pids+=("$!")
  done

  for index in "${!save_pids[@]}"; do
    pid="${save_pids[${index}]}"
    if ! wait "${pid}"; then
      log_error "$(gettext 'Failed to save Docker image'): ${save_images[${index}]}"
      save_failed=1
    fi
  done

  return "${save_failed}"
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
