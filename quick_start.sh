#!/usr/bin/env bash
#

Version=dev

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
      apk add -q gettext-dev python2
    }
    else
      echo -e "[\033[31m ERROR \033[0m] Please install it first (请先安装) $1 "
      exit 1
    fi
}

function prepare_install() {
  for i in curl wget tar; do
    command -v $i &>/dev/null || install_soft $i
  done
}

function get_installer() {
  echo "download install script to /opt/jumpserver-installer-${Version} (开始下载安装脚本到 /opt/jumpserver-installer-${Version})"
  cd /opt || exit 1
  if [ ! -d "/opt/jumpserver-installer-${Version}" ]; then
    timeout 60 wget -qO jumpserver-installer-${Version}.tar.gz https://github.com/jumpserver/installer/releases/download/${Version}/jumpserver-installer-${Version}.tar.gz || {
      rm -rf /opt/jumpserver-installer-${Version}.tar.gz
      echo -e "[\033[31m ERROR \033[0m] Failed to download jumpserver-installer-${Version} (下载 jumpserver-installer-${Version} 失败, 请检查网络是否正常或尝试重新执行脚本)"
      exit 1
    }
    tar -xf /opt/jumpserver-installer-${Version}.tar.gz -C /opt || {
      rm -rf /opt/jumpserver-installer-${Version}
      echo -e "[\033[31m ERROR \033[0m] Failed to unzip jumpserver-installer-${Version} (解压 jumpserver-installer-${Version} 失败, 请检查网络是否正常或尝试重新执行脚本)"
      exit 1
    }
    rm -rf /opt/jumpserver-installer-${Version}.tar.gz
  fi
}

function config_installer() {
  cd /opt/jumpserver-installer-${Version} || exit 1
  shopt -s expand_aliases
  if [[ $(uname) == 'Darwin' ]]; then
    alias sedi='sed -i ""'
  else
    alias sedi='sed -i'
  fi
  sedi "s/VERSION=.*/VERSION=${Version}/g" /opt/jumpserver-installer-${Version}/static.env
  ./jmsctl.sh install
  ./jmsctl.sh start
}

function main(){
  prepare_install
  get_installer
  config_installer
}

main
