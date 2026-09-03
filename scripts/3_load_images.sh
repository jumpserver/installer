#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

cd "${BASE_DIR}" || return
IMAGE_DIR="images"

function load_image_files() {
  local load_failed=0

  images=$(get_images)
  for image in ${images}; do
    filename=$(basename "${image}").zst
    filename_windows=${filename/:/_}
    if [[ -f ${IMAGE_DIR}/${filename_windows} ]]; then
      filename=${filename_windows}
    fi
    if [[ ! -f ${IMAGE_DIR}/${filename} ]]; then
      echo_red "$(gettext 'Docker image not found'): ${IMAGE_DIR}/${filename}"
      load_failed=1
      continue
    fi

    echo -n "${image} <= ${IMAGE_DIR}/${filename} "
    sha256_filename=$(basename "${image}").sha256
    sha256_path=${IMAGE_DIR}/${sha256_filename}
    if [[ ! -f "${sha256_path}" ]]; then
      echo
      echo_red "$(gettext 'Docker image ID file not found'): ${sha256_path}"
      load_failed=1
      continue
    fi

    image_id=$(docker image inspect -f "{{.ID}}" "${image}" 2>/dev/null || echo "")
    saved_id=$(cat "${sha256_path}")
    if [[ -z "${saved_id}" ]]; then
      echo
      echo_red "$(gettext 'Docker image ID file is empty'): ${sha256_path}"
      load_failed=1
      continue
    fi

    if [[ -z "${image_id}" || "${image_id}" != "${saved_id}" ]]; then
      echo
      if ! docker load <"${IMAGE_DIR}/${filename}"; then
        echo_red "$(gettext 'Error loading image'): ${filename}"
        load_failed=1
      elif ! docker image inspect "${image}" &>/dev/null; then
        echo_red "$(gettext 'Docker image not found after loading'): ${image}"
        load_failed=1
      fi
    else
      echo "$(gettext 'Docker image loaded, skipping')"
    fi
  done
  return "${load_failed}"
}

function main() {
  if [[ -d "${IMAGE_DIR}" && $(find "${IMAGE_DIR}" -type f -name "*.zst" -print -quit 2>/dev/null) ]]; then
    load_image_files || return 1
  else
    pull_images || return 1
  fi
  echo_done
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
