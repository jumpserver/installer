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

export DOCKER_COMPOSE_VERSION=v2.27.1
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
    DOCKER_COMPOSE_MD5=24120814a7df4f78aca2a31b17067e64
    ;;
  "aarch64")
    DOCKER_MD5=eac2f5b6ad2c29d1ca46d22b29c5edd3
    DOCKER_COMPOSE_MD5=553e16f35beca0e3ee09425db7ceb546
    ;;
  "loongarch64")
    DOCKER_MD5=a3d5d528210cd29872622513c6533078
    DOCKER_COMPOSE_MD5=af46b5338ec398e2d1c3b68f6e7ace2e
    ;;
  "s390x")
    DOCKER_MD5=2b910e8455d36aa3f6733c7c43126200
    DOCKER_COMPOSE_MD5=ef119360c5f1a0d4dc9c10bef5e9c1b7
    ;;
esac

export DOCKER_MD5
export DOCKER_BIN_URL="${DOCKER_MIRROR}/${ARCH}/docker-${DOCKER_VERSION}.tgz"

export DOCKER_COMPOSE_MD5
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH}"