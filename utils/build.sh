#!/bin/bash -i
#
# 该build基于registry.fit2cloud.com/public/python:3
set -eo pipefail
umask go-w
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

if [[ -e .git ]]; then
  command -v git || yum -q -y install git
  git -c tar.umask=0022 archive --format=tar HEAD | tar --no-same-permissions -xf - -C "${to_dir}"
else
  for entry in *; do
    [[ "${entry}" == release ]] && continue
    cp -R -- "${entry}" "${to_dir}/"
  done
fi

shopt -s expand_aliases
if [[ $(uname) == 'Darwin' ]]; then
  alias sedi='sed -i ""'
else
  alias sedi='sed -i'
fi

# 修改版本号文件
if [[ -n ${VERSION} ]]; then
  sedi "s@VERSION=.*@VERSION=\"${VERSION}\"@g" "${to_dir}/static.env"
fi
