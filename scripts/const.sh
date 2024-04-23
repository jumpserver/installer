#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

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
export DOCKER_VERSION=26.1.0
export DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"
export DOCKER_BIN_URL="${DOCKER_MIRROR}/$(uname -m)/docker-${DOCKER_VERSION}.tgz"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_MD5=344e9cc48a523725fc1b3b2ce0d9fb30
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_MD5=81ff95d539a16a7382819d026d64d918
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_MD5=0071150b3931cf6bc2d9e5d23dc112c7
fi
if [[ "$(uname -m)" == "s390x" ]]; then
  DOCKER_MD5=09bd1754c83e683e7caf826c5fb788c3
fi
export DOCKER_MD5

export DOCKER_COMPOSE_VERSION=v2.27.0
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-$(uname -m)"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_COMPOSE_MD5=891a283d0e11bbff04b8347d7611500a
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_COMPOSE_MD5=798dde95d63ebff0e92d986848848967
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_COMPOSE_MD5=83f554dafd26e6892d1a4c73ea95bc12
fi
if [[ "$(uname -m)" == "s390x" ]]; then
  DOCKER_COMPOSE_MD5=f7cbe603e2a0b8921f392549a6480a1a
fi
export DOCKER_COMPOSE_MD5
