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
export DOCKER_VERSION=26.1.4
export DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"

export DOCKER_COMPOSE_VERSION=v2.28.0
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"

ARCH=$(uname -m)
if [ -n "${BUILD_ARCH}" ]; then
  ARCH=${BUILD_ARCH}
fi

export ARCH

# 使用 case 语句处理不同的架构
case "${ARCH}" in
  "x86_64")
    DOCKER_MD5=99ba6d75fe9972405083b2bd911fd37b
    DOCKER_COMPOSE_MD5=fa5fe3bca5d12435d07e05ad53cf55a6
    ;;
  "aarch64")
    DOCKER_MD5=eac2f5b6ad2c29d1ca46d22b29c5edd3
    DOCKER_COMPOSE_MD5=7f270f803805c8a72033c5186b0f3b84
    ;;
  "loongarch64")
    DOCKER_MD5=a3d5d528210cd29872622513c6533078
    DOCKER_COMPOSE_MD5=38530057002b8517759262e501869adb
    ;;
  "s390x")
    DOCKER_MD5=2b910e8455d36aa3f6733c7c43126200
    DOCKER_COMPOSE_MD5=610fc7074048f122e1b23752ba612f3a
    ;;
esac

export DOCKER_MD5
export DOCKER_BIN_URL="${DOCKER_MIRROR}/${ARCH}/docker-${DOCKER_VERSION}.tgz"

export DOCKER_COMPOSE_MD5
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH}"