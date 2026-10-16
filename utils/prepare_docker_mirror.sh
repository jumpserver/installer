#!/usr/bin/env bash

# Stage verified installer dependencies using the upstream URL paths as OSS keys.
set -euo pipefail

mirror_project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mirror_output_dir=${1:?Usage: prepare_docker_mirror.sh OUTPUT_DIR [DOCKER_VERSION] [COMPOSE_VERSION]}
mirror_docker_version=${2:-}
mirror_compose_version=${3:-}
mirror_docker_version=${mirror_docker_version#v}
mirror_compose_version=${mirror_compose_version#v}
if [[ ( -n "${2:-}" && -z "${mirror_docker_version}" ) || ( -n "${3:-}" && -z "${mirror_compose_version}" ) ]]; then
  echo 'Invalid version: a v prefix must be followed by a version number' >&2
  exit 1
fi
for mirror_version in "${mirror_docker_version}" "${mirror_compose_version}"; do
  if [[ -n "${mirror_version}" && ! "${mirror_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9][a-zA-Z0-9.-]*)?$ ]]; then
    echo "Invalid version: ${mirror_version}" >&2
    exit 1
  fi
done
[[ -z "${mirror_compose_version}" ]] || mirror_compose_version="v${mirror_compose_version}"
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
  local url=$1 expected=$2 new_version=${3:-0} relative_path target actual
  if [[ ! "${expected}" =~ ^[a-f0-9]{64}$ && !( -z "${expected}" && "${new_version}" == 1 ) ]]; then
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
  if [[ -n "${expected}" && "${actual}" != "${expected}" ]]; then
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
    mirror_new_docker=0 mirror_new_compose=0
    if [[ -n "${mirror_docker_version}" && "${mirror_docker_version}" != "${DOCKER_VERSION}" ]]; then
      DOCKER_VERSION=${mirror_docker_version}
      DOCKER_BIN_URL="https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_VERSION}.tgz"
      DOCKER_BIN_SHA256=''
      mirror_new_docker=1
    fi
    if [[ -n "${mirror_compose_version}" && "${mirror_compose_version}" != "${DOCKER_COMPOSE_VERSION}" ]]; then
      DOCKER_COMPOSE_VERSION=${mirror_compose_version}
      COMPOSE_BIN_URL="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH}"
      COMPOSE_BIN_SHA256=''
      mirror_new_compose=1
    fi
    download_verified "${DOCKER_BIN_URL}" "${DOCKER_BIN_SHA256}" "${mirror_new_docker}"
    download_verified "${COMPOSE_BIN_URL}" "${COMPOSE_BIN_SHA256}" "${mirror_new_compose}"
  )
done

if [[ -n "${mirror_docker_version}" || -n "${mirror_compose_version}" ]]; then
  python3 "${mirror_project_dir}/utils/update_docker_versions.py" \
    "${mirror_project_dir}/scripts/const.sh" "${mirror_output_dir}" \
    "${mirror_docker_version}" "${mirror_compose_version}"
fi
