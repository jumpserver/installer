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
export DOCKER_VERSION=23.0.5
export DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"
export DOCKER_BIN_URL="${DOCKER_MIRROR}/$(uname -m)/docker-${DOCKER_VERSION}.tgz"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_MD5=548ef22488de0c29c5e318b2ceb0ee38
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_MD5=1126217e05c929c92d42671d86c218dc
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_MD5=a56d06928121effaf011cd116e348d9f
fi
export DOCKER_MD5

export DOCKER_COMPOSE_VERSION=v2.17.3
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-$(uname -m)"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_COMPOSE_MD5=18de31bb2d442cc76a0baa8e5eb4a34f
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_COMPOSE_MD5=21e8dd3557573d8367357ba3238ca506
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_COMPOSE_MD5=45c275eb50bf7eb022b28a5cce86eb19
fi
export DOCKER_COMPOSE_MD5
