#!/usr/bin/env bash

namespace=${NAMESPACE:-jumpserver}

function get_db_images() {
  get_db_info "image"
}

function get_pull_images() {
  use_xpack=$(get_config_or_env USE_XPACK)
  images=("redis:7.4.6-bookworm")
  images+=("$(get_db_images)")
  enabled_services=$(get_enabled_services)

  for service in ${enabled_services}; do
    if [[ "${service}" == "video" ]]; then
      image="jumpserver/video-worker:${VERSION}"
    elif [[ "${service}" == "" || "${service}" == "celery" ]]; then
      continue
    else
      image="jumpserver/${service}:${VERSION}"
    fi
    images+=("${image}")
  done
  echo "${images[@]}"
}

function get_images() {
  use_xpack=$(get_config_or_env USE_XPACK)
  images=("redis:7.4.6-bookworm")
  images+=("$(get_db_images)")
  enabled_services=$(get_enabled_services)

  for service in ${enabled_services}; do
    if [[ "${service}" == "video" ]]; then
      image="${namespace}/video-worker:${VERSION}"
    elif [[ "${service}" == "" || "${service}" == "celery" ]]; then
      continue
    else
      image="${namespace}/${service}:${VERSION}"
    fi
    images+=("${image}")
  done
  echo "${images[@]}"
}


function image_has_prefix() {
  if [[ $1 =~ jumpserver.* ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function check_image_exists() {
  image=$1
  if docker image inspect -f '{{ .Id }}' "$image" &>/dev/null; then
    echo "1"
  else
    echo "0"
  fi
}

function get_image_full_path() {
  image=$1
  DOCKER_IMAGE_MIRROR=$(get_config_or_env 'DOCKER_IMAGE_MIRROR')
  IMAGE_PULL_POLICY=$(get_config_or_env 'IMAGE_PULL_POLICY')
  DOCKER_IMAGE_PREFIX=$(get_config_or_env 'DOCKER_IMAGE_PREFIX')

  if [[ -n "${REGISTRY}" ]]; then
    DOCKER_IMAGE_MIRROR="1"
    DOCKER_IMAGE_PREFIX="${REGISTRY}/jumpserver"
  fi
  if [[ "${DOCKER_IMAGE_MIRROR}" == "1" ]]; then
    if [[ -z "${DOCKER_IMAGE_PREFIX}" ]]; then
      DOCKER_IMAGE_PREFIX="registry.cn-beijing.aliyuncs.com/jumpservice"
    fi
  fi

  full_image_path="${image}"
  if [[ -n "${DOCKER_IMAGE_PREFIX}" ]]; then
    if echo "${DOCKER_IMAGE_PREFIX}" | grep -q "/";then
      app=$(echo "$image" | awk -F'/' '{ print $NF }')
      full_image_path="${DOCKER_IMAGE_PREFIX}/${app}"
    elif [[ $(image_has_prefix "${image}") != "1" ]]; then
      full_image_path="${DOCKER_IMAGE_PREFIX}/jumpserver/${image}"
    else
      full_image_path="${DOCKER_IMAGE_PREFIX}/${image}"
    fi
  fi

  echo "${full_image_path}"
}

function pull_image() {
  image=$1
  full_image_path=$(get_image_full_path "${image}")

  pull_args=""
  case "${BUILD_ARCH}" in
    "x86_64") pull_args="--platform linux/amd64" ;;
    "aarch64") pull_args="--platform linux/arm64" ;;
    "loongarch64") pull_args="--platform linux/loong64" ;;
    "s390x") pull_args="--platform linux/s390x" ;;
  esac

  echo "[${image}] pulling"

  if [[ "${full_image_path}" != "${image}" ]]; then
    echo "  -> [${full_image_path}]"
  fi

  echo "$(check_image_exists "${image}")"
  to_image="${image}"
  if [[ -n "${NAMESPACE}" ]]; then
    to_image=${to_image/jumpserver/${NAMESPACE}}
  fi
  if [[ "$(check_image_exists "${full_image_path}")" != "1" || "$IMAGE_PULL_POLICY" == "Always" ]]; then
    docker pull ${pull_args} "${full_image_path}"
  fi
  
  if [[ "${full_image_path}" != "${to_image}" ]]; then
    docker tag "${full_image_path}" "${to_image}"
  fi
  echo ""
}


function pull_images() {
  images_to=$(get_pull_images)
  pids=()

  if [[ -n "${REGISTRY}" ]]; then
    images_to=$(echo "${images_to}" | sed "s|${REGISTRY}||g")
  fi

  trap 'kill ${pids[*]}' SIGINT SIGTERM

  for image in ${images_to}; do
    pull_image "$image" &
    pids+=($!)
  done
  wait ${pids[*]}

  trap - SIGINT SIGTERM
}

