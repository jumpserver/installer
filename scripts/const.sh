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
export DOCKER_VERSION=27.1.1
export DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"

export DOCKER_COMPOSE_VERSION=v2.29.1
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"

ARCH=$(uname -m)
if [ -n "${BUILD_ARCH}" ]; then
  ARCH=${BUILD_ARCH}
fi

export ARCH

# 使用 case 语句处理不同的架构
case "${ARCH}" in
  "x86_64")
    DOCKER_MD5=211fdb6b73f0c6b5bf3fd1643d0c5722
    DOCKER_COMPOSE_MD5=bb1c341cf694485ca9d80472e2f6e649
    ;;
  "aarch64")
    DOCKER_MD5=2db7c56ab22a5ef7f0db60362630b94d
    DOCKER_COMPOSE_MD5=314d93e17f0e15d1cc7e5399d74296aa
    ;;
  "loongarch64")
    DOCKER_MD5=539878286d77f9e9c3e3aaf5b7312d4e
    DOCKER_COMPOSE_MD5=d13a6e56683d97f3e87254f9c584aab8
    ;;
  "s390x")
    DOCKER_MD5=c1b5907a77755cc51166d7f750da1447
    DOCKER_COMPOSE_MD5=cae72cf584c8651b1adf9e3194f0b5bd
    ;;
esac

export DOCKER_MD5
export DOCKER_BIN_URL="${DOCKER_MIRROR}/${ARCH}/docker-${DOCKER_VERSION}.tgz"

export DOCKER_COMPOSE_MD5
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH}"