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
export DOCKER_VERSION=25.0.3
export DOCKER_MIRROR="https://download.jumpserver.org/docker/docker-ce/linux/static/stable"
export DOCKER_BIN_URL="${DOCKER_MIRROR}/$(uname -m)/docker-${DOCKER_VERSION}.tgz"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_MD5=0ba827cc2a1bd3c4e61c424d81148be7
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_MD5=b103d07e8dffeb601128186f6aa0e714
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_MD5=8eea6349b4fbda3fd9a0499ec7f03259
fi
if [[ "$(uname -m)" == "s390x" ]]; then
  DOCKER_MD5=10d9d1a0c771ebcfbf078a3141d72154
fi
export DOCKER_MD5

export DOCKER_COMPOSE_VERSION=v2.24.5
export DOCKER_COMPOSE_MIRROR="https://download.jumpserver.org/docker/compose/releases/download"
export DOCKER_COMPOSE_BIN_URL="${DOCKER_COMPOSE_MIRROR}/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-$(uname -m)"
if [[ "$(uname -m)" == "x86_64" ]]; then
  DOCKER_COMPOSE_MD5=aea273a344c430d1c89d23b21fa18f63
fi
if [[ "$(uname -m)" == "aarch64" ]]; then
  DOCKER_COMPOSE_MD5=3202cc80ff6147d6eb823151c8889622
fi
if [[ "$(uname -m)" == "loongarch64" ]]; then
  DOCKER_COMPOSE_MD5=a7a3372132ba4b241635b06eb74b2a45
fi
if [[ "$(uname -m)" == "s390x" ]]; then
  DOCKER_COMPOSE_MD5=53b35fe65a92175ce5dff8ee4e715df5
fi
export DOCKER_COMPOSE_MD5
