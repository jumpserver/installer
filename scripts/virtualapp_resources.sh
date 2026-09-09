#!/usr/bin/env bash
# Retain this installer's offline resources for remote Linux publishers.
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

function file_sha256() {
  local file=$1
  (
    set -o pipefail
    if command -v sha256sum &>/dev/null; then
      sha256sum <"${file}" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
      shasum -a 256 <"${file}" | awk '{print $1}'
    else
      log_error 'sha256sum or shasum is required to verify offline resources' >&2
      return 1
    fi
  )
}

function docker_architecture() {
  local filename=$1 member bytes machine
  local -a header
  member=$(
    set -o pipefail
    tar -tzf "${filename}" | awk '
      /^(\.\/)*docker\/docker$/ { print; count++ }
      END { if (count != 1) exit 1 }
    '
  ) || {
    log_error "Docker archive must contain one docker/docker binary: ${filename}" >&2
    return 1
  }
  # Inspect the ELF header without executing or extracting the binary to disk.
  # Drain the stream so tar still reports a truncated or invalid archive.
  bytes=$(
    set -o pipefail
    tar -xOzf "${filename}" "${member}" | {
      dd bs=1 count=20 2>/dev/null | od -An -v -tu1 || return 1
      cat >/dev/null
    }
  ) || {
    log_error "Cannot read Docker binary: ${filename}" >&2
    return 1
  }
  read -r -a header <<<"${bytes//$'\n'/ }" || return 1
  if [[ ${#header[@]} -ne 20 || "${header[0]} ${header[1]} ${header[2]} ${header[3]}" != '127 69 76 70' ]]; then
    log_error "Invalid Docker ELF header: ${filename}" >&2
    return 1
  fi
  case "${header[5]}" in
    1) machine=$((header[18] + header[19] * 256)) ;;
    2) machine=$((header[18] * 256 + header[19])) ;;
    *) log_error "Invalid Docker ELF byte order: ${filename}" >&2; return 1 ;;
  esac
  case "${machine}" in
    62) printf 'amd64\n' ;;
    183) printf 'arm64\n' ;;
    22) printf 's390x\n' ;;
    21)
      if [[ ${header[5]} -eq 1 ]]; then
        printf 'ppc64le\n'
      else
        printf 'ppc64\n'
      fi
      ;;
    258) printf 'loong64\n' ;;
    *) log_error "Unsupported Docker binary architecture: ${filename}" >&2; return 1 ;;
  esac
}

function load_manifest() {
  local filename=$1 manifest match
  local docker_pattern='^"docker":\{"architecture":"([a-z0-9]+)","version":"([a-zA-Z0-9][a-zA-Z0-9._+-]*)","file":"docker-([a-f0-9]{64})\.tar\.gz","sha256":"([a-f0-9]{64})"\}'
  local panda_pattern='^"panda":\{"image":"([a-zA-Z0-9][a-zA-Z0-9._:/@-]*)","architecture":"([a-z0-9]+)","image_id":"(sha256:[a-f0-9]{64})","file":"panda-([a-f0-9]{64})\.zst","sha256":"([a-f0-9]{64})"\}$'

  if [[ -L "${filename}" || ( -e "${filename}" && ! -f "${filename}" ) ]]; then
    log_error "Expected a regular virtual app manifest file: ${filename}" >&2
    return 1
  fi
  [[ -f "${filename}" ]] || return 0
  # This private manifest has fixed keys, field order and unescaped scalar values.
  # Reject other input; never evaluate JSON as Shell code.
  manifest=$(
    set -o pipefail
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      -e 's/":[[:space:]]*/":/g' -e 's/,[[:space:]]*"/,"/g' "${filename}" | tr -d '\r\n'
  ) || return 1
  [[ "${manifest}" == \{*\} ]] || return 1
  manifest=${manifest#\{}
  manifest=${manifest%\}}
  if [[ "${manifest}" =~ ${docker_pattern} ]]; then
    match=${BASH_REMATCH[0]}
    docker_arch=${BASH_REMATCH[1]}
    saved_docker_version=${BASH_REMATCH[2]}
    docker_hash=${BASH_REMATCH[3]}
    [[ "${docker_hash}" == "${BASH_REMATCH[4]}" ]] || return 1
    docker_entry=$(printf '"docker": {"architecture": "%s", "version": "%s", "file": "docker-%s.tar.gz", "sha256": "%s"}' \
      "${docker_arch}" "${saved_docker_version}" "${docker_hash}" "${docker_hash}") || return 1
    manifest=${manifest#"${match}"}
    if [[ -n "${manifest}" ]]; then
      [[ "${manifest}" == ,\"panda\":* ]] || return 1
      manifest=${manifest#,}
    fi
  fi
  if [[ -n "${manifest}" ]]; then
    [[ "${manifest}" =~ ${panda_pattern} ]] || return 1
    saved_panda_image=${BASH_REMATCH[1]}
    panda_arch=${BASH_REMATCH[2]}
    saved_panda_id=${BASH_REMATCH[3]}
    panda_hash=${BASH_REMATCH[4]}
    [[ "${panda_hash}" == "${BASH_REMATCH[5]}" ]] || return 1
    panda_entry=$(printf '"panda": {"image": "%s", "architecture": "%s", "image_id": "%s", "file": "panda-%s.zst", "sha256": "%s"}' \
      "${saved_panda_image}" "${panda_arch}" "${saved_panda_id}" "${panda_hash}" "${panda_hash}") || return 1
  fi
}

function cached_archive_matches() {
  local filename=$1 expected=$2 actual
  [[ -n "${expected}" && -f "${filename}" && ! -L "${filename}" ]] || return 1
  actual=$(file_sha256 "${filename}") || return 1
  [[ "${actual}" == "${expected}" ]]
}

function retain_archive() {
  local source=$1 name=$2 expected=${3:-} target temporary='' actual suffix
  suffix=zst
  [[ "${name}" != docker ]] || suffix=tar.gz
  (
    trap 'rm -f "${temporary}"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    temporary=$(mktemp "${destination}/.resource-XXXXXX") || return 1
    # Hash the same bytes being copied, without rereading a large source archive.
    actual=$(
      set -o pipefail
      tee "${temporary}" <"${source}" | file_sha256 /dev/stdin
    ) || return 1
    if [[ ! "${actual}" =~ ^[a-f0-9]{64}$ || ( -n "${expected}" && "${actual}" != "${expected}" ) ]]; then
      log_error "Archive SHA-256 mismatch: ${source}" >&2
      return 1
    fi
    target="${destination}/${name}-${actual}.${suffix}"
    if [[ -L "${target}" || ( -e "${target}" && ! -f "${target}" ) ]]; then
      log_error "Expected a regular virtual app archive file: ${target}" >&2
      return 1
    fi
    if ! cached_archive_matches "${target}" "${actual}"; then
      chmod 0644 "${temporary}" || return 1
      if [[ ! -e "${target}" ]]; then
        : >"${lock_dir}/${target##*/}" || return 1
      fi
      # Replacing the inode preserves hard links held by running deployment tasks.
      mv -f "${temporary}" "${target}" || return 1
    fi
    printf '%s\n' "${actual}"
  )
}

function cleanup_preparation() {
  local marker basename reference reference_status
  rm -f "${manifest_tmp}" "${service_tmp}"
  for marker in "${lock_dir}"/panda-*.zst "${lock_dir}"/docker-*.tar.gz; do
    [[ -f "${marker}" && ! -L "${marker}" ]] || continue
    basename=${marker##*/}
    [[ "${basename}" =~ ^(panda-[a-f0-9]{64}\.zst|docker-[a-f0-9]{64}\.tar\.gz)$ ]] || continue
    reference="\"file\":[[:space:]]*\"${basename//./\\.}\""
    # The on-disk manifest also protects a commit interrupted immediately after mv.
    reference_status=1
    if [[ -e "${destination}/manifest.json" || -L "${destination}/manifest.json" ]]; then
      reference_status=0
      grep -Eq "${reference}" "${destination}/manifest.json" 2>/dev/null || reference_status=$?
    fi
    if [[ "${reference_status}" == 1 ]]; then
      rm -f "${destination}/${basename}" || log_warn "Cannot remove unpublished virtual app resource: ${destination}/${basename}"
    elif [[ "${reference_status}" != 0 ]]; then
      log_warn "Cannot read resource manifest; keeping archive: ${destination}/${basename}"
    fi
    rm -f "${marker}" || log_warn "Cannot remove virtual app resource marker: ${marker}"
  done
  rmdir "${lock_dir}" || log_warn "Cannot release virtual app resource lock: ${lock_dir}"
}

function clean_archives() {
  local filename basename
  for filename in "${destination}"/panda-*.zst "${destination}"/docker-*.tar.gz; do
    [[ -f "${filename}" && ! -L "${filename}" ]] || continue
    basename=${filename##*/}
    [[ "${basename}" =~ ^(panda-[a-f0-9]{64}\.zst|docker-[a-f0-9]{64}\.tar\.gz)$ ]] || continue
    [[ "${basename}" != "panda-${panda_hash}.zst" && "${basename}" != "docker-${docker_hash}.tar.gz" ]] || continue
    # Only unlink the old name; already staged Core hard links remain usable.
    rm -f "${filename}" || log_warn "Cannot remove old virtual app resource: ${filename}"
  done
}

function main() (
  if [[ $# -ne 6 ]]; then
    log_error 'Expected images directory, Docker archive, destination, image, Docker version and checksum' >&2
    return 1
  fi
  local images_dir=$1 docker_file=$2 destination=$3 image=$4 docker_version=$5 docker_checksum=$6
  local basename=${image##*/} panda_file id_file image_id details actual_id current_arch os extra
  local panda_hash='' docker_hash='' docker_arch='' panda_arch='' separator='' manifest_tmp='' lock_dir
  local panda_entry='' docker_entry='' saved_panda_image='' saved_panda_id='' saved_docker_version=''
  local service_file="${BASE_DIR}/docker/docker.service" service_target="${destination}/docker.service" service_tmp=''

  panda_file="${images_dir}/${basename}.zst"
  if [[ -f "${images_dir}/${basename//:/_}.zst" ]]; then
    panda_file="${images_dir}/${basename//:/_}.zst"
  fi
  # Online installs leave the last usable offline resources untouched.
  [[ -f "${panda_file}" || -f "${docker_file}" ]] || return 0
  mkdir -p "${destination}" || return 1
  lock_dir="${destination}/.prepare.lock"
  if ! mkdir "${lock_dir}" 2>/dev/null; then
    if [[ -d "${lock_dir}" ]]; then
      log_warn "Virtual app resource directory is locked; skipping: ${lock_dir}"
      return 0
    fi
    log_error "Cannot lock virtual app resources: ${lock_dir}" >&2
    return 1
  fi
  trap cleanup_preparation EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! load_manifest "${destination}/manifest.json"; then
    log_error 'Invalid virtual app resource manifest; keeping existing resources' >&2
    return 1
  fi
  if [[ ! -f "${panda_file}" && -n "${panda_hash}" ]] &&
    ! cached_archive_matches "${destination}/panda-${panda_hash}.zst" "${panda_hash}"; then
    log_error "Invalid retained Panda archive: ${destination}/panda-${panda_hash}.zst" >&2
    return 1
  fi
  if [[ ! -f "${docker_file}" && -n "${docker_hash}" ]] &&
    ! cached_archive_matches "${destination}/docker-${docker_hash}.tar.gz" "${docker_hash}"; then
    log_error "Invalid retained Docker archive: ${destination}/docker-${docker_hash}.tar.gz" >&2
    return 1
  fi
  if [[ -f "${panda_file}" ]]; then
    # Only fixed keys and validated scalar values enter the JSON manifest.
    if [[ ! "${image}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$ ]]; then
      log_error "Invalid Panda image reference: ${image}" >&2
      return 1
    fi
    id_file="${images_dir}/${basename}.sha256"
    image_id=$(cat "${id_file}") || return 1
    if [[ ! "${image_id}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
      log_error "Invalid Docker image ID: ${id_file}" >&2
      return 1
    fi
    details=$(docker image inspect --format '{{.Id}} {{.Architecture}} {{.Os}}' "${image}" 2>/dev/null) || details=''
    if [[ "${details%% *}" != "${image_id}" ]]; then
      docker load <"${panda_file}" || return 1
      details=$(docker image inspect --format '{{.Id}} {{.Architecture}} {{.Os}}' "${image}") || return 1
    fi
    read -r actual_id current_arch os extra <<<"${details}" || return 1
    if [[ "${actual_id}" != "${image_id}" || "${os}" != linux || -n "${extra}" ]]; then
      log_error "Loaded Panda image does not match the offline package: ${image}" >&2
      return 1
    fi
    case "${current_arch}" in
      amd64|arm64|s390x|ppc64le|ppc64|loong64) ;;
      *) log_error "Unsupported Panda image architecture: ${current_arch}" >&2; return 1 ;;
    esac
    if [[ "${saved_panda_image}" != "${image}" || "${saved_panda_id}" != "${image_id}" ||
      "${panda_arch}" != "${current_arch}" ]] ||
      ! cached_archive_matches "${destination}/panda-${panda_hash}.zst" "${panda_hash}"; then
      panda_hash=$(retain_archive "${panda_file}" panda) || return 1
    fi
    panda_arch=${current_arch}
    panda_entry=$(printf '"panda": {"image": "%s", "architecture": "%s", "image_id": "%s", "file": "panda-%s.zst", "sha256": "%s"}' \
      "${image}" "${panda_arch}" "${image_id}" "${panda_hash}" "${panda_hash}") || return 1
  fi

  if [[ -f "${docker_file}" ]]; then
    if [[ ! "${docker_version}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]]; then
      log_error "Invalid Docker version: ${docker_version}" >&2
      return 1
    fi
    docker_checksum=$(printf '%s' "${docker_checksum}" | tr 'A-F' 'a-f') || return 1
    if [[ -z "${docker_checksum}" || "${docker_checksum}" != "${docker_hash}" ||
      "${saved_docker_version}" != "${docker_version}" ]] ||
      ! cached_archive_matches "${destination}/docker-${docker_hash}.tar.gz" "${docker_hash}"; then
      docker_arch=$(docker_architecture "${docker_file}") || return 1
      docker_hash=$(retain_archive "${docker_file}" docker "${docker_checksum}") || return 1
    fi
    if [[ -f "${panda_file}" && "${panda_arch}" != "${docker_arch}" ]]; then
      log_error 'Panda image and Docker binary have different architectures' >&2
      return 1
    fi
    docker_entry=$(printf '"docker": {"architecture": "%s", "version": "%s", "file": "docker-%s.tar.gz", "sha256": "%s"}' \
      "${docker_arch}" "${docker_version}" "${docker_hash}" "${docker_hash}") || return 1
  fi

  manifest_tmp=$(mktemp "${destination}/.manifest-XXXXXX") || return 1
  {
    printf '{\n' || return 1
    if [[ -n "${docker_entry}" ]]; then
      printf '  %s' "${docker_entry}" || return 1
      separator=','
    fi
    if [[ -n "${panda_entry}" ]]; then
      printf '%s\n  %s' "${separator}" "${panda_entry}" || return 1
    fi
    printf '\n}\n' || return 1
  } >"${manifest_tmp}" || return 1
  chmod 0644 "${manifest_tmp}" || return 1
  if [[ -f "${docker_file}" ]]; then
    if [[ ! -f "${service_file}" ]]; then
      log_error "Docker service file not found: ${service_file}" >&2
      return 1
    fi
    if [[ -L "${service_target}" || ( -e "${service_target}" && ! -f "${service_target}" ) ]]; then
      log_error "Expected a regular Docker service file: ${service_target}" >&2
      return 1
    fi
    if ! cmp -s "${service_file}" "${service_target}"; then
      service_tmp=$(mktemp "${destination}/.docker-service-XXXXXX") || return 1
      cp "${service_file}" "${service_tmp}" || return 1
      chmod 0644 "${service_tmp}" || return 1
      mv -f "${service_tmp}" "${service_target}" || return 1
    fi
  fi
  if ! cmp -s "${manifest_tmp}" "${destination}/manifest.json"; then
    mv -f "${manifest_tmp}" "${destination}/manifest.json" || return 1
  fi
  clean_archives
  printf 'Virtual app offline resources: %s/manifest.json\n' "${destination}"
)

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main "$@"
fi
