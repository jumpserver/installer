#!/usr/bin/env bash

function get_db_images() {
  get_db_info "image"
}

function get_image_namespace() {
  local namespace

  namespace=$(get_config_or_env NAMESPACE jumpserver)
  namespace=${namespace%/}
  echo "${namespace:-jumpserver}"
}

function get_image_pull_prefix() {
  local image_pull_prefix registry

  image_pull_prefix=$(get_config_or_env IMAGE_PULL_PREFIX)
  if [[ -n "${image_pull_prefix}" ]]; then
    echo "${image_pull_prefix%/}"
    return 0
  fi

  # Compatibility for existing CI jobs. REGISTRY historically meant the
  # registry root containing the jumpserver namespace.
  registry=$(get_config_or_env REGISTRY)
  if [[ -n "${registry}" ]]; then
    echo "${registry%/}/jumpserver"
  fi
}

function emit_image_mapping() {
  local source_image=$1 target_image=$2 exact_source=${3:-0}

  printf '%s\t%s\t%s\n' "${source_image}" "${target_image}" "${exact_source}"
}

function get_image_mappings() {
  local use_xpack enabled_services service image db_image namespace

  use_xpack=$(get_config_or_env USE_XPACK)
  namespace=$(get_image_namespace)
  emit_image_mapping "redis:7.4.10-bookworm" "redis:7.4.10-bookworm"
  db_image=$(get_db_images)
  if [[ -n "${db_image}" ]]; then
    emit_image_mapping "${db_image}" "${db_image}"
  fi

  enabled_services=${OFFLINE_IMAGE_SERVICES:-$(get_enabled_services)}
  enabled_services=${enabled_services//,/ }

  for service in ${enabled_services}; do
    case "${service}" in
      "" | celery | jdmc)
        ;;
      *)
        emit_image_mapping \
          "jumpserver/${service}:${VERSION}" \
          "${namespace}/${service}:${VERSION}"
        ;;
    esac
  done

  if [[ "${use_xpack}" == "1" ]]; then
    emit_image_mapping \
      "jumpserver/ansible-executor:latest" \
      "${namespace}/ansible-executor:latest"
  fi
  if should_include_openbao_image; then
    image=$(get_openbao_image)
    emit_image_mapping "${image}" "${image}"
  fi
  if should_include_jdmc_image; then
    emit_image_mapping \
      "jumpserver/jdmc:${VERSION}" \
      "${namespace}/jdmc:${VERSION}"
  fi
}

function get_pull_images() {
  local source_image target_image exact_source
  local -a images=()

  while IFS=$'\t' read -r source_image target_image exact_source; do
    [[ -n "${source_image}" ]] && images+=("${source_image}")
  done < <(get_image_mappings)

  echo "${images[@]}"
}

function get_images() {
  local source_image target_image exact_source
  local -a images=()

  while IFS=$'\t' read -r source_image target_image exact_source; do
    [[ -n "${target_image}" ]] && images+=("${target_image}")
  done < <(get_image_mappings)

  echo "${images[@]}"
}

function get_offline_image_manifest() {
  local source_image target_image exact_source resolved_source

  while IFS=$'\t' read -r source_image target_image exact_source; do
    [[ -n "${source_image}" && -n "${target_image}" ]] || continue
    if [[ "${exact_source}" == "1" ]]; then
      resolved_source=${source_image}
    else
      resolved_source=$(get_image_full_path "${source_image}")
    fi
    printf '%s\t%s\n' "${resolved_source}" "${target_image}"
  done < <(get_image_mappings)
}

function image_has_prefix() {
  case "$1" in
    jumpserver/*) echo "1" ;;
    *) echo "0" ;;
  esac
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
  local image=$1 image_pull_prefix image_pull_scope
  local docker_image_mirror docker_image_prefix
  local full_image_path app

  if image_is_registry_qualified "${image}"; then
    echo "${image}"
    return 0
  fi

  image_pull_prefix=$(get_image_pull_prefix)
  image_pull_scope=$(get_config_or_env IMAGE_PULL_SCOPE jumpserver)
  if [[ -n "${image_pull_prefix}" ]]; then
    if [[ "${image_pull_scope}" == "all" || $(image_has_prefix "${image}") == "1" ]]; then
      app=${image##*/}
      echo "${image_pull_prefix}/${app}"
    else
      # Infrastructure images retain their own registry and namespace.
      echo "${image}"
    fi
    return 0
  fi

  # Compatibility with the previous mirror configuration.
  docker_image_mirror=$(get_config_or_env DOCKER_IMAGE_MIRROR)
  docker_image_prefix=$(get_config_or_env DOCKER_IMAGE_PREFIX)
  if [[ "${docker_image_mirror}" == "1" ]]; then
    if [[ -z "${docker_image_prefix}" ]]; then
      docker_image_prefix="registry.cn-beijing.aliyuncs.com/jumpservice"
    fi
  fi

  full_image_path="${image}"
  if [[ -n "${docker_image_prefix}" ]]; then
    if [[ $(image_uses_mirror_prefix "${image}") != "1" ]]; then
      full_image_path="${image}"
    elif echo "${docker_image_prefix}" | grep -q "/";then
      app=${image##*/}
      full_image_path="${docker_image_prefix%/}/${app}"
    elif [[ $(image_has_prefix "${image}") != "1" ]]; then
      full_image_path="${docker_image_prefix}/jumpserver/${image}"
    else
      full_image_path="${docker_image_prefix}/${image}"
    fi
  fi

  echo "${full_image_path}"
}

function pull_image() {
  local image=$1 requested_target=${2:-} exact_source=${3:-0}
  local full_image_path pull_args to_image image_pull_policy namespace

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
  if [[ -z "${requested_target}" && "${to_image}" == jumpserver/* ]]; then
    namespace=$(get_image_namespace)
    to_image="${namespace}/${to_image#jumpserver/}"
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
  local source_image target_image pid
  local pull_failed=0
  local -a pids=()

  trap 'kill ${pids[*]}' SIGINT SIGTERM

  while IFS=$'\t' read -r source_image target_image; do
    [[ -n "${source_image}" && -n "${target_image}" ]] || continue
    pull_image "${source_image}" "${target_image}" 1 &
    pids+=("$!")
  done < <(get_offline_image_manifest)
  for pid in "${pids[@]}"; do
    if ! wait "${pid}"; then
      pull_failed=1
    fi
  done

  trap - SIGINT SIGTERM
  return "${pull_failed}"
}
