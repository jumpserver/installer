#!/usr/bin/env bash

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/docker-mirror"
mkdir -p "${test_dir}"

(
  unset DOCKER_BIN_HOST DOCKER_IMAGE_MIRROR
  export BUILD_ARCH=arm64
  . "${TEST_ROOT}/scripts/const.sh"
  docker_path="linux/static/stable/aarch64/docker-${DOCKER_VERSION}.tgz"
  compose_path="docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-aarch64"
  assert_eq "https://download.docker.com/${docker_path}" "${DOCKER_BIN_URL}"
  assert_eq "https://github.com/${compose_path}" "${COMPOSE_BIN_URL}"

  export DOCKER_IMAGE_MIRROR=1
  . "${TEST_ROOT}/scripts/const.sh"
  assert_eq "https://download.jumpserver.org/${docker_path}" "${DOCKER_BIN_URL}"
  assert_eq "https://download.jumpserver.org/${compose_path}" "${COMPOSE_BIN_URL}"
  unset DOCKER_IMAGE_MIRROR
  export DOCKER_BIN_HOST=https://env.example.com
  . "${TEST_ROOT}/scripts/const.sh"
  assert_eq "https://env.example.com/${docker_path}" "${DOCKER_BIN_URL}"
  assert_eq "https://env.example.com/${compose_path}" "${COMPOSE_BIN_URL}"
)
printf 'PASS: const.sh official and mirror URLs, arm64 alias and custom host\n'
