#!/usr/bin/env bash

# Stage verified installer dependencies using the upstream URL paths as OSS keys.
set -euo pipefail

mirror_project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mirror_output_dir=${1:?Usage: prepare_docker_mirror.sh OUTPUT_DIR}
mkdir -p "${mirror_output_dir}"
mirror_output_dir="$(cd "${mirror_output_dir}" && pwd)"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

md5_file() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | awk '{print $1}'
  else
    md5 -q "$1"
  fi
}

download_verified() {
  local url=$1 expected=$2 relative_path target actual
  if [[ ! "${expected}" =~ ^[a-f0-9]{64}$ ]]; then
    echo "Missing or invalid pinned SHA-256 for ${url}" >&2
    return 1
  fi
  relative_path=${url#https://}
  relative_path=${relative_path#*/}
  target="${mirror_output_dir}/${relative_path}"
  mkdir -p "$(dirname "${target}")"
  echo "Downloading ${url}"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 600 \
    "${url}" -o "${target}.part"
  actual=$(sha256_file "${target}.part")
  if [[ "${actual}" != "${expected}" ]]; then
    rm -f "${target}.part"
    echo "SHA-256 verification failed for ${url}" >&2
    return 1
  fi
  mv "${target}.part" "${target}"
  printf '%s\n' "${actual}" >"${target}.sha256"
  md5_file "${target}" >"${target}.md5"
}

for mirror_arch in x86_64 aarch64; do
  (
    # Always fetch upstream, regardless of the caller's mirror configuration.
    export BUILD_ARCH=${mirror_arch}
    unset DOCKER_BIN_HOST DOCKER_IMAGE_MIRROR
    . "${mirror_project_dir}/scripts/const.sh"
    download_verified "${DOCKER_BIN_URL}" "${DOCKER_BIN_SHA256}"
    download_verified "${COMPOSE_BIN_URL}" "${COMPOSE_BIN_SHA256}"
  )
done
