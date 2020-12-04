#!/bin/bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

export SCRIPT_DIR="$BASE_DIR"
PROJECT_DIR=$(dirname "${SCRIPT_DIR}")

STATIC_ENV=${PROJECT_DIR}/static.env
# shellcheck source=../static.env
source "${STATIC_ENV}"

export OS=$(uname -s)
export DOCKER_VERSION=19.03.14
export DOCKER_MD5=dfa385b37c444c7d97fe78bd5148299d
export DOCKER_MIRROR="https://mirrors.aliyun.com/docker-ce/linux/static/stable"
DOCKER_BIN_URL="${DOCKER_MIRROR}/$(uname -m)/docker-${DOCKER_VERSION}.tgz"
export DOCKER_BIN_URL

export DOCKER_COMPOSE_VERSION=1.27.4
export DOCKER_COMPOSE_MD5=bec660213f97d788d129410d047f261f
export DOCKER_COMPOSE_MIRROR="https://get.daocloud.io/docker/compose/releases/download"
DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"
export DOCKER_COMPOSE_BIN_URL
