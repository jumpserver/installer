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
export DOCKER_VERSION=26.0.0
export DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"
export DOCKER_BIN_URL="${DOCKER_MIRROR}/$(uname -m)/docker-${DOCKER_VERSION}.tgz"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_MD5=908fb24b8e3712199b30d4b381af9bba
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_MD5=b4868578258823e4b6ba1b83048dc5c1
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_MD5=fb04660cdb594e2628361a0591078958
fi
if [[ "$(uname -m)" == "s390x" ]]; then
  DOCKER_MD5=f417e4e6480c630ad3e527706610aa82
fi
export DOCKER_MD5

export DOCKER_COMPOSE_VERSION=v2.26.1
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-$(uname -m)"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_COMPOSE_MD5=d0e38e2a1ec580a77feea34f466df81c
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_COMPOSE_MD5=13e42b2e23dc23c9ac3a37932aa0e28a
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_COMPOSE_MD5=e38fad868cbcc2b3e2ef33d14ab28fe9
fi
if [[ "$(uname -m)" == "s390x" ]]; then
  DOCKER_COMPOSE_MD5=665143c87c8486d51df44da22313ad73
fi
export DOCKER_COMPOSE_MD5
