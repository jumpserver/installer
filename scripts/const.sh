#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export SCRIPT_DIR="$BASE_DIR"
PROJECT_DIR=$(dirname "${SCRIPT_DIR}")

if [[ ! "$(echo $PATH | grep /usr/local/bin)" ]]; then
  export PATH=/usr/local/bin:$PATH
fi

# 国际化处理
export TEXTDOMAINDIR=$PROJECT_DIR/locale
export TEXTDOMAIN=jumpserver-installer

export CONFIG_DIR='/opt/jumpserver/config'
export CONFIG_FILE=$CONFIG_DIR/config.txt

# Compose 项目设置
export COMPOSE_PROJECT_NAME=jms
# export COMPOSE_HTTP_TIMEOUT=3600
# export DOCKER_CLIENT_TIMEOUT=3600

STATIC_ENV=${PROJECT_DIR}/static.env
# shellcheck source=../static.env
. "${STATIC_ENV}"

export OS=$(uname -s)
export DOCKER_VERSION=28.5.1
DOCKER_URL="https://download.docker.com/linux/static/stable"
DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"

if [[ "${USE_MIRROR}" == "1" ]];then
  DOCKER_URL=${DOCKER_MIRROR}
fi

export DOCKER_COMPOSE_VERSION=v2.40.3
COMPOSE_URL="https://github.com/docker/compose/releases/download"
COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"
if [[ "${USE_MIRROR}" == "1" ]];then
  COMPOSE_URL=${COMPOSE_MIRROR}
fi

ARCH=$(uname -m)
if [ -n "${BUILD_ARCH}" ]; then
  ARCH=${BUILD_ARCH}
fi

export ARCH
export DOCKER_BIN_URL="${DOCKER_URL}/${ARCH}/docker-${DOCKER_VERSION}.tgz"
export DOCKER_MD5_URL="${DOCKER_MIRROR}/${ARCH}/docker-${DOCKER_VERSION}.tgz.md5"
export COMPOSE_BIN_URL="${COMPOSE_URL}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH}"
export COMPOSE_MD5_URL="${COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH}.md5"