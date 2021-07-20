#!/bin/bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

export SCRIPT_DIR="$BASE_DIR"
PROJECT_DIR=$(dirname "${SCRIPT_DIR}")

# 国际化处理
export TEXTDOMAINDIR=$PROJECT_DIR/locale
export TEXTDOMAIN=jumpserver-installer

export CONFIG_DIR='/opt/jumpserver/config'
export CONFIG_FILE=$CONFIG_DIR/config.txt

STATIC_ENV=${PROJECT_DIR}/static.env
# shellcheck source=../static.env
. "${STATIC_ENV}"

export OS=$(uname -s)
export DOCKER_VERSION=18.06.3-ce
export DOCKER_MIRROR="https://mirrors.ustc.edu.cn/docker-ce/linux/static/stable"
DOCKER_BIN_URL="${DOCKER_MIRROR}/$(uname -m)/docker-${DOCKER_VERSION}.tgz"
export DOCKER_BIN_URL
if [[ "$(uname -m)" == "aarch64" ]]; then
  export DOCKER_MD5=b9d7beb1e19d0ae13c0872adbb20281c
else
  export DOCKER_MD5=ea3304ea2fff21dd1e501795c43c48ff
fi

export DOCKER_COMPOSE_VERSION=1.29.2
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"
DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"
export DOCKER_COMPOSE_BIN_URL
if [[ "$(uname -m)" == "aarch64" ]]; then
  export DOCKER_COMPOSE_MD5=6477a1a275d5837106f1311a78876776
else
  export DOCKER_COMPOSE_MD5=8f68ae5d2334eecb0ee50b809b5cec58
fi
