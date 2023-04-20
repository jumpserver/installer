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
export DOCKER_VERSION=23.0.4
export DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"
export DOCKER_BIN_URL="${DOCKER_MIRROR}/$(uname -m)/docker-${DOCKER_VERSION}.tgz"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_MD5=bb699210acb708376f5229d6568e0a05
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_MD5=d09be9db1dc045d0204d5dac0db66dc3
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_MD5=9d3f90de623ad3f9a32828417bde303c
fi
export DOCKER_MD5

export DOCKER_COMPOSE_VERSION=v2.17.2
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-$(uname -m)"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_COMPOSE_MD5=374917f8a2a90c24fda2a1f80013948a
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_COMPOSE_MD5=9a7c942724059bdb5a17dfe502b1d9bc
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_COMPOSE_MD5=5c905b61b254a919cad1f730ff89f641
fi
export DOCKER_COMPOSE_MD5
