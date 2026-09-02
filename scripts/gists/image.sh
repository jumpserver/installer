#!/usr/bin/env bash

namespace=${NAMESPACE:-jumpserver}

function get_db_images() {
  get_db_info "image"
}

function get_pull_images() {
  use_xpack=$(get_config_or_env USE_XPACK)
  images=("redis:7.4.10-bookworm")
  images+=("$(get_db_images)")
  enabled_services=$(get_enabled_services)

  for service in ${enabled_services}; do
    if [[ "${service}" == "video" ]]; then
      image="jumpserver/video-worker:${VERSION}"
    elif [[ "${service}" == "" || "${service}" == "celery" || "${service}" == "ai" ]]; then
      continue
    else
      image="jumpserver/${service}:${VERSION}"
    fi
    images+=("${image}")
  done
  if [[ "${use_xpack}" == "1" ]]; then
    images+=("jumpserver/ansible-executor:latest")
  fi
  if should_include_openbao_image; then
    images+=("$(get_openbao_image)")
  fi
  if should_include_jdmc_image; then
    images+=("$(get_jdmc_pull_image)")
  fi
  echo "${images[@]}"
}

function get_images() {
  use_xpack=$(get_config_or_env USE_XPACK)
  images=("redis:7.4.10-bookworm")
  images+=("$(get_db_images)")
  enabled_services=$(get_enabled_services)

  for service in ${enabled_services}; do
    if [[ "${service}" == "video" ]]; then
      image="${namespace}/video-worker:${VERSION}"
    elif [[ "${service}" == "" || "${service}" == "celery" || "${service}" == "ai" ]]; then
      continue
    else
      image="${namespace}/${service}:${VERSION}"
    fi
    images+=("${image}")
  done
  if [[ "${use_xpack}" == "1" ]]; then
    images+=("${namespace}/ansible-executor:latest")
  fi
  if should_include_openbao_image; then
    images+=("$(get_openbao_image)")
  fi
  if should_include_jdmc_image; then
    images+=("$(get_jdmc_image)")
  fi
  echo "${images[@]}"
}


function image_has_prefix() {
  if [[ $1 =~ jumpserver.* ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function image_uses_mirror_prefix() {
  image=$1

  # Infrastructure images are pulled directly from Docker Hub. Only
  # JumpServer application images and the remaining third-party images use
  # the configured internal mirror.
  case "${image}" in
    redis|redis:*|redis@*|postgres|postgres:*|postgres@*|openbao|openbao:*|openbao@*|openbao/openbao|openbao/openbao:*|openbao/openbao@*)
      echo "0"
      return
      ;;
  esac

  if [[ "${image}" != */* || $(image_has_prefix "${image}") == "1" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function image_is_registry_qualified() {
  local image=$1 first_component

  [[ "${image}" == */* ]] || return 1
  first_component=${image%%/*}
  [[ "${first_component}" == "localhost" ||
    "${first_component}" == *.* ||
    "${first_component}" == *:* ]]
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

  if image_is_registry_qualified "${image}"; then
    echo "${image}"
    return 0
  fi

  if [[ -n "${REGISTRY:-}" ]]; then
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
    if [[ $(image_uses_mirror_prefix "${image}") != "1" ]]; then
      full_image_path="${image}"
    elif echo "${DOCKER_IMAGE_PREFIX}" | grep -q "/";then
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
  local image=$1 requested_target=${2:-} exact_source=${3:-0}
  local full_image_path pull_args to_image image_pull_policy

  if [[ "${exact_source}" == "1" ]]; then
    full_image_path="${image}"
  else
    full_image_path=$(get_image_full_path "${image}")
  fi
  image_pull_policy=$(get_config_or_env 'IMAGE_PULL_POLICY')

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
  if [[ -n "${requested_target}" ]]; then
    to_image="${requested_target}"
  else
    to_image="${image}"
  fi
  if [[ -z "${requested_target}" && -n "${NAMESPACE:-}" && "${to_image}" == jumpserver/* ]]; then
    to_image="${NAMESPACE}/${to_image#jumpserver/}"
  fi
  if [[ "$(check_image_exists "${full_image_path}")" != "1" || "${image_pull_policy}" == "Always" ]]; then
    if ! docker pull -q ${pull_args} "${full_image_path}"; then
      echo "[${image}] pull failed" >&2
      return 1
    fi
  fi
  
  if [[ "${full_image_path}" != "${to_image}" ]]; then
    if ! docker tag "${full_image_path}" "${to_image}"; then
      echo "[${image}] tag failed: ${full_image_path} -> ${to_image}" >&2
      return 1
    fi
  fi
  echo ""
  return 0
}


function pull_images() {
  local images_to image pid jdmc_pull_image="" jdmc_target_image=""
  local pull_failed=0
  local -a pids=()

  images_to=$(get_pull_images)
  if should_include_jdmc_image; then
    jdmc_pull_image=$(get_jdmc_pull_image)
    jdmc_target_image=$(get_jdmc_image)
  fi

  trap 'kill ${pids[*]}' SIGINT SIGTERM

  for image in ${images_to}; do
    if [[ -n "${jdmc_pull_image}" && "${image}" == "${jdmc_pull_image}" ]]; then
      if [[ -n "${JDMC_IMAGE:-}" ]]; then
        pull_image "${image}" "${jdmc_target_image}" 1 &
      else
        pull_image "${image}" "${jdmc_target_image}" &
      fi
    else
      pull_image "${image}" &
    fi
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    if ! wait "${pid}"; then
      pull_failed=1
    fi
  done

  trap - SIGINT SIGTERM
  return "${pull_failed}"
}
