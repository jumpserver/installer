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
export DOCKER_MD5=ea3304ea2fff21dd1e501795c43c48ff
export DOCKER_MIRROR="https://mirrors.ustc.edu.cn/docker-ce/linux/static/stable"
DOCKER_BIN_URL="${DOCKER_MIRROR}/$(uname -m)/docker-${DOCKER_VERSION}.tgz"
export DOCKER_BIN_URL

export DOCKER_COMPOSE_VERSION=1.27.4
export DOCKER_COMPOSE_MD5=bec660213f97d788d129410d047f261f
export DOCKER_COMPOSE_MIRROR="https://get.daocloud.io/docker/compose/releases/download"
DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"
export DOCKER_COMPOSE_BIN_URL
