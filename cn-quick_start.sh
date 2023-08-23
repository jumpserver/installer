#!/usr/bin/env bash
#

VERSION=v3.6.2
DOWNLOAD_URL=https://resource.fit2cloud.com

function install_soft() {
    if command -v dnf > /dev/null; then
      dnf -q -y install "$1"
    elif command -v yum > /dev/null; then
      yum -q -y install "$1"
    elif command -v apt > /dev/null; then
      apt-get -qqy install "$1"
    elif command -v zypper > /dev/null; then
      zypper -q -n install "$1"
    elif command -v apk > /dev/null; then
      apk add -q "$1"
      command -v gettext >/dev/null || {
      apk add -q gettext-dev python3
    }
    else
      echo -e "[\033[31m ERROR \033[0m] $1 command not found, Please install it first"
      exit 1
    fi
}

function prepare_install() {
  for i in curl wget tar iptables; do
    command -v $i &>/dev/null || install_soft $i
  done
}

function get_installer() {
  echo "download install script to /opt/jumpserver-installer-${VERSION}"
  cd /opt || exit 1
  if [ ! -d "/opt/jumpserver-installer-${VERSION}" ]; then
    timeout 60 wget -qO jumpserver-installer-${VERSION}.tar.gz ${DOWNLOAD_URL}/jumpserver/installer/releases/download/${VERSION}/jumpserver-installer-${VERSION}.tar.gz || {
      rm -f /opt/jumpserver-installer-${VERSION}.tar.gz
      echo -e "[\033[31m ERROR \033[0m] Failed to download jumpserver-installer-${VERSION}"
      exit 1
    }
    tar -xf /opt/jumpserver-installer-${VERSION}.tar.gz -C /opt || {
      rm -rf /opt/jumpserver-installer-${VERSION}
      echo -e "[\033[31m ERROR \033[0m] Failed to unzip jumpserver-installer-${VERSION}"
      exit 1
    }
    rm -f /opt/jumpserver-installer-${VERSION}.tar.gz
  fi
}

function config_installer() {
  cd /opt/jumpserver-installer-${VERSION} || exit 1
  sed -i "s/VERSION=.*/VERSION=${VERSION}/g" /opt/jumpserver-installer-${VERSION}/static.env
  sed -i "s/# DOCKER_IMAGE_MIRROR=1/DOCKER_IMAGE_MIRROR=1/g" /opt/jumpserver-installer-${VERSION}/config-example.txt
  ./jmsctl.sh install
  ./jmsctl.sh start
}

function main(){
  if [[ "${OS}" == 'Darwin' ]]; then
    echo
    echo "Unsupported Operating System Error"
    exit 1
  fi
  prepare_install
  get_installer
  config_installer
}

main
