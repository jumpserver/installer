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
export DOCKER_VERSION=27.0.3
export DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"

export DOCKER_COMPOSE_VERSION=v2.29.0
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"

ARCH=$(uname -m)
if [ -n "${BUILD_ARCH}" ]; then
  ARCH=${BUILD_ARCH}
fi

export ARCH

# 使用 case 语句处理不同的架构
case "${ARCH}" in
  "x86_64")
    DOCKER_MD5=f2dd63a7ec8d56b3b4fad28c59967f5c
    DOCKER_COMPOSE_MD5=df4050371096c8ea38f044cb6a74d9d8
    ;;
  "aarch64")
    DOCKER_MD5=a6e096151704a89a8d3a2beb70e6bb6b
    DOCKER_COMPOSE_MD5=026eef68d6658b6a76a1e0db64dae2b9
    ;;
  "loongarch64")
    DOCKER_MD5=a6bed0b96f12c14263ccea9a40d4961c
    DOCKER_COMPOSE_MD5=96448f0ae80761d50652c719434ec0ff
    ;;
  "s390x")
    DOCKER_MD5=b303546b603ff472830ea9ff141c431b
    DOCKER_COMPOSE_MD5=33db9467493e39515537b7857456ecb8
    ;;
esac

export DOCKER_MD5
export DOCKER_BIN_URL="${DOCKER_MIRROR}/${ARCH}/docker-${DOCKER_VERSION}.tgz"

export DOCKER_COMPOSE_MD5
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH}"