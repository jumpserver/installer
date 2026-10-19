#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

cd "${BASE_DIR}" || return
IMAGE_DIR="images"

function load_image_files() {
  local result=0
  images=$(get_images)
  for image in ${images}; do
    filename=$(basename "${image}").zst
    filename_windows=${filename/:/_}
    if [[ -f ${IMAGE_DIR}/${filename_windows} ]]; then
      filename=${filename_windows}
    fi
    if [[ ! -f ${IMAGE_DIR}/${filename} ]]; then
      echo_red "$(gettext 'Docker image not found'): ${IMAGE_DIR}/${filename}"
      result=1
      continue
    fi

    echo -n "${image} <= ${IMAGE_DIR}/${filename} "
    md5_filename=$(basename "${image}").md5
    md5_path=${IMAGE_DIR}/${md5_filename}
    image_id=$(docker image inspect -f "{{.ID}}" "${image}" 2>/dev/null || true)
    saved_id=""

    if [[ -f "${md5_path}" ]]; then
      saved_id=$(cat "${md5_path}")
    fi
    if [[ -z "${image_id}" || ${image_id} != "${saved_id}" ]]; then
      echo
      if ! docker load <"${IMAGE_DIR}/${filename}"; then
        echo_red "$(gettext 'Error loading image'): ${filename}"
        result=1
      fi
    else
      echo "$(gettext 'Docker image loaded, skipping')"
    fi
  done
  return "${result}"
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
