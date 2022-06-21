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

STATIC_ENV=${PROJECT_DIR}/static.env
# shellcheck source=../static.env
. "${STATIC_ENV}"

export OS=$(uname -s)
export DOCKER_VERSION=20.10.17
export DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"
export DOCKER_BIN_URL="${DOCKER_MIRROR}/$(uname -m)/docker-${DOCKER_VERSION}.tgz"

if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_MD5=f9b6570a174df41aec6b822fba7a17aa
fi
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_MD5=f8c950e9d4edb901c0a8124706f60919
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_MD5=6c6fc22839c1bbe3ce578c470c2cd719
fi
export DOCKER_MD5

export DOCKER_COMPOSE_VERSION=1.29.2
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"

if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_COMPOSE_MD5=6477a1a275d5837106f1311a78876776
fi
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_COMPOSE_MD5=8f68ae5d2334eecb0ee50b809b5cec58
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_COMPOSE_MD5=0b060d00fbc20f3f9c2f231e944db9b5
fi
export DOCKER_COMPOSE_MD5
