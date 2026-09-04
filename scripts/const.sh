#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export SCRIPT_DIR="$BASE_DIR"
PROJECT_DIR=$(dirname "${SCRIPT_DIR}")

if [[ ! "$(echo $PATH | grep /usr/local/bin)" ]]; then
  export PATH=/usr/local/bin:$PATH
fi

# 国际化处理
export TEXTDOMAINDIR=$PROJECT_DIR/locale
export TEXTDOMAIN=jumpserver-installer

export CONFIG_DIR="${JS_CONFIG_DIR:-/opt/jumpserver/config}"
export CONFIG_FILE=$CONFIG_DIR/config.txt
export CONFIG_SAFE_FILE=$CONFIG_DIR/config_safe.txt

# Compose 项目设置
export COMPOSE_PROJECT_NAME=jms
# export COMPOSE_HTTP_TIMEOUT=3600
# export DOCKER_CLIENT_TIMEOUT=3600

STATIC_ENV=${PROJECT_DIR}/static.env
# shellcheck source=../static.env
. "${STATIC_ENV}"

export OS=$(uname -s)
export DOCKER_VERSION=29.7.2
export DOCKER_COMPOSE_VERSION=v2.40.3

ARCH=$(uname -m)
if [ -n "${BUILD_ARCH:-}" ]; then
  ARCH=${BUILD_ARCH}
fi
[[ "${ARCH}" == "arm64" ]] && ARCH=aarch64

export ARCH
DOCKER_BIN_URL="https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_VERSION}.tgz"
COMPOSE_BIN_URL="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${ARCH}"

case "${DOCKER_VERSION}:${ARCH}" in
  29.7.2:x86_64) DOCKER_BIN_SHA256=803d433f226db4776e1768fd319fc6c6e4935a456acf84fcc0080818b854bc8f ;;
  29.7.2:aarch64) DOCKER_BIN_SHA256=43d143448adf2c2787704e7d7704fd6d62d367a54c5edaef0a3f75509cb0938d ;;
  *) DOCKER_BIN_SHA256=${DOCKER_BIN_SHA256:-} ;;
esac
case "${DOCKER_COMPOSE_VERSION}:${ARCH}" in
  v2.40.3:x86_64) COMPOSE_BIN_SHA256=dba9d98e1ba5bfe11d88c99b9bd32fc4a0624a30fafe68eea34d61a3e42fd372 ;;
  v2.40.3:aarch64) COMPOSE_BIN_SHA256=d26373b19e89160546d15407516cc59f453030d9bc5b43ba7faf16f7b4980137 ;;
  *) COMPOSE_BIN_SHA256=${COMPOSE_BIN_SHA256:-} ;;
esac

if [[ -n ${DOCKER_BIN_HOST:-} ]];then
   DOCKER_BIN_URL=$(echo "$DOCKER_BIN_URL" | sed "s@https://download.docker.com@${DOCKER_BIN_HOST}@g")
   COMPOSE_BIN_URL=$(echo "$COMPOSE_BIN_URL" | sed "s@https://github.com@${DOCKER_BIN_HOST}@g" )
fi
export DOCKER_BIN_URL=$DOCKER_BIN_URL
export COMPOSE_BIN_URL=$COMPOSE_BIN_URL
export DOCKER_BIN_SHA256 COMPOSE_BIN_SHA256
