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
export DOCKER_VERSION=20.10.21
export DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"
export DOCKER_BIN_URL="${DOCKER_MIRROR}/$(uname -m)/docker-${DOCKER_VERSION}.tgz"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_MD5=88f2c418a8a82a3f445ea0e820c65a1d
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_MD5=c83db4a402d53c317421e186e026c534
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_MD5=22ee8dc9582fcbb9262ddf84b8e08c35
fi
export DOCKER_MD5

export DOCKER_COMPOSE_VERSION=v2.12.2
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-$(uname -m)"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_COMPOSE_MD5=40e67c2ec8cd186c0c0016ce76e07a22
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_COMPOSE_MD5=adaa49e7915552ce9690a8e9c443a8f2
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_COMPOSE_MD5=1869304a11e8fb6ca676866c9c3ec6f5
fi
export DOCKER_COMPOSE_MD5
