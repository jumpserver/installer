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
export DOCKER_VERSION=25.0.4
export DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"
export DOCKER_BIN_URL="${DOCKER_MIRROR}/$(uname -m)/docker-${DOCKER_VERSION}.tgz"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_MD5=417e91fcf5774d0f04c58d5500b1946f
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_MD5=9095035fc0700aacfc7262cf353e91e8
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_MD5=ec3634e6fec48aedbc903a9f47f7f6b0
fi
if [[ "$(uname -m)" == "s390x" ]]; then
  DOCKER_MD5=794804888e312a8d912eac1b9a4ac3e4
fi
export DOCKER_MD5

export DOCKER_COMPOSE_VERSION=v2.24.7
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-$(uname -m)"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_COMPOSE_MD5=a24c26e39af438437c8d664f109f8456
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_COMPOSE_MD5=d094e1551cb3c4de858aaff562bcd4d8
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_COMPOSE_MD5=987b6b6964431b86979e9fe6a00f98b5
fi
if [[ "$(uname -m)" == "s390x" ]]; then
  DOCKER_COMPOSE_MD5=4b182bfbfb2ba190000b9ec2593898f1
fi
export DOCKER_COMPOSE_MD5
