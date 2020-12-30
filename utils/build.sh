#!/bin/bash -i
#
# 该build基于registry.fit2cloud.com/public/python:3
utils_dir=$(pwd)
project_dir=$(dirname "$utils_dir")
release_dir=${project_dir}/release

# 打开alias
shopt -s expand_aliases
# 打包
cd "${project_dir}" || exit 3
rm -rf "${release_dir:?}"/*
to_dir="${release_dir}/jumpserver-installer"
mkdir -p "${to_dir}"

if [[ -d '.git' ]];then
  command -v git &>/dev/null || {
    if [[ -f "/etc/redhat-release" ]]; then
      yum -q -y install git
    elif [[ -f /etc/lsb-release ]]; then
      apt-get -qqy update
      apt-get -qqy install git
    else
      echo -ne "请先安装 wget "
      echo_failed
    fi
  }
  git archive --format tar HEAD | tar x -C "${to_dir}"
else
  cp -R . /tmp/jumpserver
  mv /tmp/jumpserver/* "${to_dir}"
fi

if [[ $(uname) == 'Darwin' ]];then
  alias sedi='sed -i ""'
else
  alias sedi='sed -i'
fi

# 修改版本号文件
if [[ -n ${VERSION} ]]; then
  sedi "s@VERSION=.*@VERSION=\"${VERSION}\"@g" "${to_dir}/static.env"
fi
