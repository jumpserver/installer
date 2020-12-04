#!/bin/bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./util.sh
. "${BASE_DIR}/utils.sh"

IMAGE_DIR="images"
DOCKER_IMAGE_PREFIX="${DOCKER_IMAGE_PREFIX-}"
USE_XPACK="${USE_XPACK-0}"


function prepare_docker_bin() {
  command -v wget &> /dev/null || yum -y install wget

  md5_matched=$(check_md5 /tmp/docker.tar.gz "${DOCKER_MD5}")
  if [[ ! -f /tmp/docker.tar.gz || "${md5_matched}" != "1" ]]; then
    echo "Md5 ${DOCKER_MD5}"
    get_file_md5 /tmp/docker.tar.gz
    echo "v::          $md5_match"
    echo "开始下载 Docker 程序 ..."
    wget "${DOCKER_BIN_URL}" -O /tmp/docker.tar.gz
  else
    echo "使用 Docker 缓存文件: /tmp/docker.tar.gz"
  fi
  cp /tmp/docker.tar.gz . && tar xzf docker.tar.gz && rm -f docker.tar.gz

  md5_matched=$(check_md5 /tmp/docker-compose "${DOCKER_COMPOSE_MD5}")
  if [[ ! -f /tmp/docker-compose || "${md5_matched}" != "1" ]]; then
    echo "开始下载 Docker compose 程序 ..."
    wget "${DOCKER_COMPOSE_BIN_URL}" -O /tmp/docker-compose
  else
    echo "使用 Docker compose 缓存文件: /tmp/docker-compose"
  fi
  cp /tmp/docker-compose docker/
  chmod +x docker/*
  export PATH=$PATH:$(pwd)/docker
}


function prepare_image_files() {
  ps aux | grep -v 'grep' | grep 'docker' &> /dev/null
  if [[ "$?" != "0" ]];then
    echo "Docker 没有运行, 请安装并启动"
    exit 1
  fi

  scope="public"
  if [[ "${USE_XPACK}" == "1" ]]; then
    scope="all"
  fi
  images=$(get_images $scope)
  i=0
  for image in ${images}; do
    ((i++)) || true
    echo "[${image}]"
    if [[ -n "${DOCKER_IMAGE_PREFIX}" ]]; then
      docker pull "${DOCKER_IMAGE_PREFIX}/${image}"
      docker tag "${DOCKER_IMAGE_PREFIX}/${image}" "${image}"
    else
      docker pull "${image}"
    fi
    filename=$(basename "${image}").tar
    component=$(echo "${filename}" | awk -F: '{ print $1 }')
    md5_filename=$(basename "${image}").md5
    md5_path=${IMAGE_DIR}/${md5_filename}

    image_id=$(docker inspect -f "{{.ID}}" ${image})
    saved_id=""
    if [[ -f "${md5_path}" ]]; then
      saved_id=$(cat "${md5_path}")
    fi

    mkdir -p "${IMAGE_DIR}"
    if [[ ${image_id} != "${saved_id}" ]]; then
      rm -f ${IMAGE_DIR}/${component}*
      image_path="${IMAGE_DIR}/${filename}"
      echo "保存镜像 ${image} -> ${image_path}"
      docker save -o "${image_path}" "${image}" && echo "${image_id}" >"${md5_path}"
    else
      echo "已加载过该镜像, 跳过: ${image}"
    fi
    echo
  done

}

function make_release() {
  release_version=$1
  BUILD_NUMBER=${BUILD_NUMBER-1}

  sed -i "s@VERSION=.*@VERSION=${release_version}@g" "${PROJECT_DIR}/static.env"

  echo "一、 准备离线包内容"
  rm -f "${IMAGE_DIR}"/*.tar
  rm -f "${IMAGE_DIR}"/*.md5
  prepare

  echo "二、 打包"
  cwd=$(pwd)
  package_name=$(basename "${PROJECT_DIR}")
  release_name="jumpserver-release-${release_version}-$BUILD_NUMBER"

  cd "${PROJECT_DIR}/.." || exit
  echo "1. 拷贝内容"
  time cp -r "${package_name}" "${release_name}"
  cd "${release_name}" && rm -rf hudson.* .travis.yml .git
  cd ..

  echo -e "\n2. 压缩包"
  time zip -r "${release_name}.zip" "${release_name}" -x '*.git*' '*hudson*' '*travis.yml*'
  md5=$(get_file_md5 "${release_name}.zip")

  echo 'md5:' "$md5" >"${release_name}.md5"
  release_dir="${PROJECT_DIR}/releases"
  mkdir -p "${release_dir}"
  rm -f "${release_dir}"/*.zip "${release_dir}"/*md5
  mv "${release_name}.zip" "${release_name}.md5" "${release_dir}"
  echo -e "\n3. 离线生成完成: ${release_dir}/${release_name}.zip"

  cd "${cwd}" || exit
}

function prepare() {
  echo "1. 准备 Docker 离线包"
  prepare_docker_bin

  echo -e "\n2. 准备镜像离线包"
  prepare_image_files
}

if [[ "$0" = "$BASH_SOURCE"  ]]; then
  case "$1" in
  run)
    prepare
    ;;
  prepare)
    prepare
    ;;
  release)
    make_release "$2"
    ;;
  *)
    echo "Usage: $0 run | prepare | release VERSION"
    ;;
  esac
fi
