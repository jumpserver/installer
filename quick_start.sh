#!/usr/bin/env bash
#

VERSION=${VERSION:-dev}
DOWNLOAD_URL=${DOWNLOAD_URL:-https://github.com}
OS=$(uname -s)

function install_soft() {
    if command -v dnf &>/dev/null; then
      dnf -q -y install "$1"
    elif command -v yum &>/dev/null; then
      yum -q -y install "$1"
    elif command -v apt &>/dev/null; then
      apt-get -qqy install "$1"
    elif command -v zypper &>/dev/null; then
      zypper -q -n install "$1"
    elif command -v apk &>/dev/null; then
      apk add -q "$1"
      command -v gettext &>/dev/null || {
      apk add -q gettext-dev python3
    }
    else
      echo -e "[\033[31m ERROR \033[0m] $1 command not found, Please install it first"
      exit 1
    fi
}

function prepare_install() {
  for i in curl wget tar gettext; do
    command -v $i &>/dev/null || install_soft $i
  done
  command -v sha256sum &>/dev/null || install_soft coreutils
}

function get_installer() {
  echo "download install script to /opt/jumpserver-installer-${VERSION}"
  cd /opt || exit 1
  if [ ! -d "/opt/jumpserver-installer-${VERSION}" ]; then
    archive="jumpserver-installer-${VERSION}.tar.gz"
    checksum="${archive}.sha256"
    timeout 60 wget -qO "${archive}" "${DOWNLOAD_URL}/jumpserver/installer/releases/download/${VERSION}/${archive}" || {
      rm -f /opt/jumpserver-installer-${VERSION}.tar.gz
      echo -e "[\033[31m ERROR \033[0m] Failed to download jumpserver-installer-${VERSION}"
      exit 1
    }
    timeout 60 wget -qO "${checksum}" "${DOWNLOAD_URL}/jumpserver/installer/releases/download/${VERSION}/${checksum}" || {
      rm -f "${archive}" "${checksum}"
      echo -e "[\033[31m ERROR \033[0m] Failed to download installer checksum"
      exit 1
    }
    if ! sha256sum -c "${checksum}"; then
      rm -f "${archive}" "${checksum}"
      echo -e "[\033[31m ERROR \033[0m] Installer checksum verification failed"
      exit 1
    fi
    tar --no-same-owner -xf "/opt/${archive}" -C /opt || {
      rm -rf /opt/jumpserver-installer-${VERSION}
      echo -e "[\033[31m ERROR \033[0m] Failed to unzip jumpserver-installer-${VERSION}"
      exit 1
    }
    rm -f "/opt/${archive}" "/opt/${checksum}"
  fi
}

function config_installer() {
  cd /opt/jumpserver-installer-${VERSION} || exit 1
  ./jmsctl.sh install || exit 1
  ./jmsctl.sh start || exit 1
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
