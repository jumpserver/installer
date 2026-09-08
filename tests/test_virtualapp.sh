#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/virtualapp"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
printf '%s\n' 'USE_XPACK=1' 'NAMESPACE=registry.internal/custom' >"${test_dir}/config.txt"
. "${TEST_ROOT}/scripts/utils.sh"

if get_images | grep -q '/panda:'; then
  fail 'Runtime image loading must not require Panda'
fi
mappings=$(INCLUDE_PANDA_IMAGE=1 OFFLINE_IMAGE_SERVICES='core,panda' get_image_mappings)
assert_contains "${mappings}" $'jumpserver/panda:' 'EE bundles must carry Panda'
assert_contains "${mappings}" "registry.internal/custom/panda:${VERSION}"
assert_eq 1 "$(printf '%s\n' "${mappings}" | grep -c '^jumpserver/panda:')" 'Panda must occur once'
if get_enabled_services | grep -w panda >/dev/null; then
  fail 'Panda must not become a local Compose service'
fi
assert_contains "$(get_offline_image_manifest)" 'jumpserver/panda:' 'CI offline manifests must include Panda'
if INCLUDE_PANDA_IMAGE=0 get_offline_image_manifest | grep -q 'jumpserver/panda:'; then
  fail 'Explicit runtime manifests must exclude Panda'
fi
(
  pull_image() { printf '%s\n' "$2" >>"${test_dir}/pulled-images"; }
  OFFLINE_IMAGE_SERVICES='core,panda' pull_images
  if grep -q '/panda:' "${test_dir}/pulled-images"; then
    fail 'Runtime pulls must not include Panda'
  fi
  : >"${test_dir}/pulled-images"
  INCLUDE_PANDA_IMAGE=1 pull_images
  assert_contains "$(cat "${test_dir}/pulled-images")" "registry.internal/custom/panda:${VERSION}" 'Bundling must pull Panda'
)
printf '%s\n' 'USE_XPACK=0' >"${test_dir}/config.txt"
if INCLUDE_PANDA_IMAGE=1 get_image_mappings | grep -q 'jumpserver/panda:'; then
  fail 'CE must not include the enterprise Panda image'
fi

images="${test_dir}/images"
output="${test_dir}/data with spaces/virtualapp"
bin_dir="${test_dir}/usr/local/bin"
export TEST_TEE_COMMAND=$(command -v tee)
export TEST_CP_COMMAND=$(command -v cp)
mkdir -p "${images}" "${bin_dir}" "${test_dir}/docker-fixture/docker"

# Use only ordinary Shell tools: neither Python nor jq is present in this PATH.
for tool in bash sh cat chmod cp mv rm mkdir mktemp dirname basename uname hostname ln \
  awk sed grep tr tar gzip dd od head tail sort cut wc find cmp stat readlink \
  sha256sum shasum date env tee rmdir; do
  tool_command=$(command -v "${tool}" || true)
  if [[ -n "${tool_command}" ]]; then
    ln -s "${tool_command}" "${bin_dir}/${tool}"
  fi
done
rm "${bin_dir}/cp"
cat >"${bin_dir}/cp" <<'CP'
#!/bin/sh
if [ "${SERVICE_COPY_FAIL:-0}" = 1 ]; then
  printf 'Cannot copy Docker service file\n' >&2
  exit 1
fi
exec "$TEST_CP_COMMAND" "$@"
CP
rm "${bin_dir}/tee"
cat >"${bin_dir}/tee" <<'TEE'
#!/bin/sh
if [ "${RESOURCE_COPY_FAIL:-0}" = 1 ]; then
  printf 'Cannot copy resource\n' >&2
  exit 1
fi
exec "$TEST_TEE_COMMAND" "$@"
TEE
cat >"${bin_dir}/docker" <<'DOCKER'
#!/bin/sh
printf '%s\n' "$1" >>"$PANDA_DOCKER_CALLS"
case "$1" in
  load)
    cat >"$PANDA_LOAD_INPUT"
    [ "${PANDA_LOAD_FAIL:-0}" != 1 ] || exit 1
    ;;
  image)
    [ "$2" = inspect ] && [ "${PANDA_INSPECT_FAIL:-0}" != 1 ] || exit 1
    actual_id=${PANDA_LOCAL_ID:-$PANDA_ID}
    [ ! -f "$PANDA_LOAD_INPUT" ] || actual_id=${PANDA_LOADED_ID:-$PANDA_ID}
    [ "$actual_id" != missing ] || exit 1
    printf '%s %s linux\n' "$actual_id" "$PANDA_ARCH"
    ;;
  *) printf 'Unexpected Docker operation: %s\n' "$*" >&2; exit 1 ;;
esac
DOCKER
chmod +x "${bin_dir}/docker" "${bin_dir}/tee" "${bin_dir}/cp"
export PATH="${bin_dir}"
for tool in python python2 python3 jq; do
  if command -v "${tool}" >/dev/null 2>&1; then
    fail "${tool} must be absent from the offline resource test PATH"
  fi
done

export PANDA_ID="sha256:$(printf '%064d' 0 | tr 0 a)"
export PANDA_ARCH=amd64
export PANDA_LOAD_INPUT="${test_dir}/loaded-panda.zst" PANDA_DOCKER_CALLS="${test_dir}/docker-calls"
image='registry.internal/custom/panda:v5.0.0-ee'
archive="${images}/panda:v5.0.0-ee.zst"
image_id="${images}/panda:v5.0.0-ee.sha256"
docker_archive="${test_dir}/docker.tar.gz"
manifest_file="${output}/manifest.json"
service_file="${output}/docker.service"
invalid_hash=$(printf '%064d' 0)

file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

run_resources() {
  local expected=${1:-0} checksum=${2-${docker_hash:-}} service_base=${3-${TEST_ROOT}/scripts} result=0
  rm -f "${PANDA_LOAD_INPUT}" "${PANDA_DOCKER_CALLS}"
  bash -c '. "$1"; BASE_DIR=$2; shift 2; main "$@"' bash \
    "${TEST_ROOT}/scripts/virtualapp_resources.sh" "${service_base}" \
    "${images}" "${docker_archive}" "${output}" "${image}" '29.7.2' "${checksum}" \
    >"${test_dir}/resource.log" 2>&1 || result=$?
  if [[ "${expected}" == '0' && "${result}" != '0' ]]; then
    cat "${test_dir}/resource.log" >&2
    fail 'Preparing valid offline resources failed'
  elif [[ "${expected}" != '0' && "${result}" == '0' ]]; then
    fail 'Preparing invalid offline resources must fail'
  fi
}

make_docker() {
  local header="${test_dir}/docker-fixture/docker/docker"
  # ELF64, little endian, followed by e_machine at bytes 18 and 19.
  printf '\177ELF\002\001\000\000\000\000\000\000\000\000\000\000\000\000' >"${header}"
  case "$1" in
    amd64) printf '\076\000' >>"${header}" ;;
    arm64) printf '\267\000' >>"${header}" ;;
    *) fail 'Unknown fixture architecture' ;;
  esac
  tar -czf "${docker_archive}" -C "${test_dir}/docker-fixture" docker/docker
}

manifest_entry() {
  tr -d '[:space:]' <"${manifest_file}" |
    sed -nE 's/^.*"'"$1"'":\{([^{}]*)\}.*$/\1/p' | tr ',' '\n' | sort
}

assert_manifest_entries() {
  local architecture=$1 expected_panda expected_docker
  expected_panda=$(printf '%s\n' \
    '"image":"'"${image}"'"' \
    '"architecture":"'"${architecture}"'"' \
    '"image_id":"'"${PANDA_ID}"'"' \
    '"sha256":"'"${archive_hash}"'"' \
    '"file":"panda-'"${archive_hash}"'.zst"' | sort)
  expected_docker=$(printf '%s\n' \
    '"architecture":"'"${architecture}"'"' \
    '"version":"29.7.2"' \
    '"sha256":"'"${docker_hash}"'"' \
    '"file":"docker-'"${docker_hash}"'.tar.gz"' | sort)
  assert_eq "${expected_panda}" "$(manifest_entry panda)" 'Panda manifest must contain exact resource identities'
  assert_eq "${expected_docker}" "$(manifest_entry docker)" 'Docker manifest must match its static package'
}

assert_previous_manifest() {
  cmp -s "${manifest_file}" "${test_dir}/previous-manifest.json" ||
    fail 'Invalid resources must preserve the complete previous manifest'
}

# An online installation must not export images or create invented metadata.
run_resources
[[ ! -e "${output}" ]] || fail 'No archives must produce no resource directory'

# A valid Zstandard frame with one uncompressed final block (19 bytes).
# Retention must preserve these bytes and the .zst extension without a zstd tool.
printf '\050\265\057\375\040\023\231\000\000offline Panda image' >"${archive}"
printf '%s\n' "${PANDA_ID}" >"${image_id}"
archive_hash=$(file_hash "${archive}")
make_docker amd64
docker_hash=$(file_hash "${docker_archive}")
PANDA_LOCAL_ID=missing run_resources 0 "${docker_hash}"
cmp -s "${PANDA_LOAD_INPUT}" "${archive}" || fail 'Missing Panda images must load the original zstd bytes'
assert_manifest_entries amd64
cmp -s "${service_file}" "${TEST_ROOT}/scripts/docker/docker.service" || fail 'The Installer Docker service must be retained unchanged'
[[ "$(find "${service_file}" -perm 0644 -print)" == "${service_file}" ]] || fail 'The retained Docker service must use mode 0644'
retained="${output}/panda-${archive_hash}.zst"
snapshot="${test_dir}/running-task-image"
ln "${retained}" "${snapshot}"
ln "${manifest_file}" "${test_dir}/unchanged-manifest"
ln "${service_file}" "${test_dir}/unchanged-service"
RESOURCE_COPY_FAIL=1 run_resources
[[ ! -e "${PANDA_LOAD_INPUT}" ]] || fail 'Matching local Panda images must not be loaded again'
[[ "${retained}" -ef "${snapshot}" ]] || fail 'Repeated installs must reuse the existing archive inode'
[[ "${manifest_file}" -ef "${test_dir}/unchanged-manifest" ]] || fail 'An unchanged manifest must not be rewritten'
[[ "${service_file}" -ef "${test_dir}/unchanged-service" ]] || fail 'An unchanged Docker service must not be rewritten'
cmp -s "${retained}" "${archive}" || fail 'The original zstd archive must be retained unchanged'

# Service copy failures keep both published files; replacement preserves staged links.
cp "${manifest_file}" "${test_dir}/previous-manifest.json"
printf 'old Docker service\n' >"${service_file}"
run_resources 1 "${docker_hash}" "${test_dir}/missing-service"
assert_previous_manifest
assert_eq 'old Docker service' "$(cat "${service_file}")" 'A missing service source must preserve the old service'
SERVICE_COPY_FAIL=1 run_resources 1
assert_previous_manifest
assert_eq 'old Docker service' "$(cat "${service_file}")" 'A failed service copy must preserve the old service'
[[ -z "$(find "${output}" -name '.docker-service-*' -print)" ]] || fail 'Failed service copies must remove temporary files'
run_resources
cmp -s "${service_file}" "${TEST_ROOT}/scripts/docker/docker.service" || fail 'A changed service must be replaced with the Installer source'
assert_eq 'old Docker service' "$(cat "${test_dir}/unchanged-service")" 'Service replacement must preserve existing task hard links'
[[ ! "${service_file}" -ef "${test_dir}/unchanged-service" ]] || fail 'Service replacement must use a new inode'

# Local Panda mismatches load the bundle; failed or incorrect loads never publish.
cp "${manifest_file}" "${test_dir}/previous-manifest.json"
PANDA_LOCAL_ID="sha256:${invalid_hash}" run_resources
[[ -f "${PANDA_LOAD_INPUT}" ]] || fail 'A different local Panda image must load the bundle'
PANDA_LOCAL_ID=missing PANDA_LOAD_FAIL=1 run_resources 1
assert_previous_manifest
PANDA_LOCAL_ID=missing PANDA_LOADED_ID="sha256:${invalid_hash}" run_resources 1
assert_previous_manifest
[[ -f "${PANDA_LOAD_INPUT}" ]] || fail 'The loaded image identity must be checked again'

# Invalid identities, mismatched architectures and checksums must be atomic.
export PANDA_INSPECT_FAIL=1
run_resources 1
assert_previous_manifest
unset PANDA_INSPECT_FAIL
printf 'sha256:%s\n' "$(printf '%064d' 0 | tr 0 b)" >"${image_id}"
run_resources 1
assert_previous_manifest
printf '%s\n' 'invalid-image-id' >"${image_id}"
run_resources 1
assert_previous_manifest
rm "${image_id}"
run_resources 1
assert_previous_manifest
printf '%s\n' "${PANDA_ID}" >"${image_id}"
run_resources
assert_previous_manifest
PANDA_ARCH=arm64
run_resources 1
assert_previous_manifest
PANDA_ARCH=amd64
run_resources 1 "${invalid_hash}"
assert_previous_manifest
printf '%s\n' 'invalid Docker archive' >"${docker_archive}"
# A matching verified cache is usable even when the unused source is damaged.
run_resources
assert_previous_manifest
# Without an expected checksum the source must be inspected and rejected.
run_resources 1 ''
assert_previous_manifest
make_docker amd64

# Repairing a retained file must replace its inode, preserving task hard links.
printf '%s' 'corrupt cache' >"${retained}"
run_resources
cmp -s "${retained}" "${archive}" || fail 'A corrupt retained archive must be repaired'
assert_eq 'corrupt cache' "$(cat "${snapshot}")" 'Existing task hard links must not be overwritten'
[[ ! "${retained}" -ef "${snapshot}" ]] || fail 'Repair must replace the destination inode'

# Recognize package architecture independently of the installation host.
old_docker="${output}/docker-${docker_hash}.tar.gz"
ln "${old_docker}" "${test_dir}/running-task-docker"
PANDA_ARCH=arm64
make_docker arm64
docker_hash=$(file_hash "${docker_archive}")
run_resources
assert_manifest_entries arm64
[[ ! -e "${old_docker}" ]] || fail 'Publishing new Docker resources must remove the old managed name'
[[ -s "${test_dir}/running-task-docker" ]] || fail 'Removing old names must preserve task hard links'

# Windows-compatible archive names retain the original Docker reference and ID.
mv "${archive}" "${images}/panda_v5.0.0-ee.zst"
archive="${images}/panda_v5.0.0-ee.zst"
run_resources
assert_manifest_entries arm64

# Failed updates and concurrent preparation must preserve the active manifest and files.
cp "${manifest_file}" "${test_dir}/previous-manifest.json"
old_panda="${retained}"
ln "${old_panda}" "${test_dir}/running-published-image"
orphan="${output}/panda-${invalid_hash}.zst"
printf 'old unused archive' >"${orphan}"
printf 'operator note' >"${output}/notes.zst"
printf 'leave this file' >"${test_dir}/external-archive"
link_hash=$(printf '%064d' 0 | tr 0 f)
ln -s "${test_dir}/external-archive" "${output}/panda-${link_hash}.zst"
mkdir "${output}/.prepare.lock"
run_resources
assert_contains "$(cat "${test_dir}/resource.log")" "[WARN] Virtual app resource directory is locked"
assert_contains "$(cat "${test_dir}/resource.log")" "${output}/.prepare.lock"
assert_previous_manifest
[[ -f "${orphan}" ]] || fail 'Lock contention must not run cleanup'
rmdir "${output}/.prepare.lock"

cp "${manifest_file}" "${test_dir}/valid-manifest.json"
printf '{"panda": invalid}\n' >"${manifest_file}"
cp "${manifest_file}" "${test_dir}/previous-manifest.json"
run_resources 1
assert_previous_manifest
[[ -f "${orphan}" ]] || fail 'Invalid manifests must not run cleanup'
cp "${test_dir}/valid-manifest.json" "${manifest_file}"
cp "${manifest_file}" "${test_dir}/previous-manifest.json"

PANDA_ID="sha256:$(printf '%064d' 0 | tr 0 c)"
printf '%s\n' "${PANDA_ID}" >"${image_id}"
printf 'updated image archive' >>"${archive}"
archive_hash=$(file_hash "${archive}")
# A directory or directory symlink must never receive an archive or manifest.
blocked_archive="${output}/panda-${archive_hash}.zst"
mkdir "${test_dir}/blocked-directory"
for target_type in directory symlink; do
  if [[ "${target_type}" == directory ]]; then
    mkdir "${blocked_archive}"
  else
    ln -s "${test_dir}/blocked-directory" "${blocked_archive}"
  fi
  run_resources 1
  assert_previous_manifest
  assert_contains "$(cat "${test_dir}/resource.log")" "Expected a regular virtual app archive file: ${blocked_archive}"
  [[ -z "$(find -H "${blocked_archive}" -mindepth 1 -print)" ]] || fail 'Archive writes must not enter a directory target'
  if [[ "${target_type}" == directory ]]; then rmdir "${blocked_archive}"; else rm "${blocked_archive}"; fi

  mv "${manifest_file}" "${test_dir}/saved-manifest.json"
  if [[ "${target_type}" == directory ]]; then
    mkdir "${manifest_file}"
  else
    ln -s "${test_dir}/blocked-directory" "${manifest_file}"
  fi
  run_resources 1
  assert_contains "$(cat "${test_dir}/resource.log")" "Expected a regular virtual app manifest file: ${manifest_file}"
  [[ -z "$(find -H "${manifest_file}" -mindepth 1 -print)" ]] || fail 'Manifest writes must not enter a directory target'
  if [[ "${target_type}" == directory ]]; then rmdir "${manifest_file}"; else rm "${manifest_file}"; fi
  mv "${test_dir}/saved-manifest.json" "${manifest_file}"
  assert_previous_manifest

  mv "${service_file}" "${test_dir}/saved-service"
  if [[ "${target_type}" == directory ]]; then
    mkdir "${service_file}"
  else
    ln -s "${test_dir}/blocked-directory" "${service_file}"
  fi
  run_resources 1
  assert_contains "$(cat "${test_dir}/resource.log")" "Expected a regular Docker service file: ${service_file}"
  [[ -z "$(find -H "${service_file}" -mindepth 1 -print)" ]] || fail 'Service writes must not enter a directory target'
  if [[ "${target_type}" == directory ]]; then rmdir "${service_file}"; else rm "${service_file}"; fi
  mv "${test_dir}/saved-service" "${service_file}"
  assert_previous_manifest
  [[ -f "${orphan}" && -f "${old_panda}" ]] || fail 'Invalid target types must not run cleanup'
done
run_resources 1 "${invalid_hash}"
assert_contains "$(cat "${test_dir}/resource.log")" "Archive SHA-256 mismatch: ${docker_archive}"
assert_previous_manifest
[[ ! -e "${blocked_archive}" ]] || fail 'A later preparation failure must remove the unpublished Panda archive'
[[ -f "${orphan}" && -f "${old_panda}" ]] || fail 'Rollback must preserve pre-existing archives'
[[ ! -e "${output}/.prepare.lock" ]] || fail 'Rollback must remove its markers and release the lock'
RESOURCE_COPY_FAIL=1 run_resources 1
assert_previous_manifest
[[ -f "${orphan}" && -f "${old_panda}" ]] || fail 'Failed copying must not run cleanup'
[[ ! -e "${output}/.prepare.lock" ]] || fail 'Failed copying must release its lock'
[[ -z "$(find "${output}" -name '.resource-*' -print)" ]] || fail 'Failed copying must remove temporary files'
run_resources
assert_manifest_entries arm64
[[ -f "${blocked_archive}" ]] || fail 'Cleanup must preserve an archive referenced by the committed manifest'
[[ ! -e "${old_panda}" && ! -e "${orphan}" ]] || fail 'Successful updates must remove only unused managed archives'
[[ -s "${test_dir}/running-published-image" ]] || fail 'Staged application archives must survive old-name cleanup'
[[ -f "${output}/notes.zst" && -L "${output}/panda-${link_hash}.zst" ]] || fail 'Cleanup must preserve unknown files and symlinks'

# Online upgrades preserve resources missing from the current package.
mv "${docker_archive}" "${test_dir}/saved-docker.tar.gz"
printf 'keep service without a Docker archive\n' >"${service_file}"
run_resources
assert_eq 'keep service without a Docker archive' "$(cat "${service_file}")" 'Panda-only resources must not replace the retained service'
mv "${test_dir}/saved-docker.tar.gz" "${docker_archive}"
rm "${archive}"
run_resources
[[ -n "$(manifest_entry panda)" ]] || fail 'An absent Panda archive must preserve the existing entry'
[[ -n "$(manifest_entry docker)" ]] || fail 'An existing Docker archive must remain in the manifest'
cp "${manifest_file}" "${test_dir}/previous-manifest.json"
rm "${docker_archive}"
ln "${service_file}" "${test_dir}/online-service"
run_resources
assert_previous_manifest
[[ "${service_file}" -ef "${test_dir}/online-service" ]] || fail 'Online packages without archives must not replace the service'
[[ ! -e "${PANDA_DOCKER_CALLS}" ]] || fail 'Online packages without archives must not invoke Docker'
(
  SCRIPT_DIR="${test_dir}/package-without-archives"
  get_config_or_env() { printf '1\n'; }
  get_config() { fail 'Packages without archives must not require VOLUME_DIR'; }
  prepare_virtualapp_resources
)

# Resource failures only warn; the main image-loading step still fails normally.
(
  . "${TEST_ROOT}/scripts/3_load_images.sh"
  export PATH="${bin_dir}"
  IMAGE_DIR="${test_dir}/package-images"
  mkdir -p "${IMAGE_DIR}"
  printf 'main image fixture\n' >"${IMAGE_DIR}/core.zst"
  load_image_files() { return "${IMAGE_STEP_FAILED:-0}"; }
  prepare_virtualapp_resources() { printf 'resources called\n' >"${test_dir}/resource-called"; return 1; }
  echo_done() { printf 'installation continued\n'; }
  if IMAGE_STEP_FAILED=1 main >"${test_dir}/load-failed.log" 2>&1; then
    fail 'An image-load failure must still fail the image step'
  fi
  [[ ! -e "${test_dir}/resource-called" ]] || fail 'Failed image loading must not prepare resources'
  main >"${test_dir}/resource-warning.log" 2>&1
  assert_contains "$(cat "${test_dir}/resource-warning.log")" '[WARN] Virtual app offline resources could not be prepared'
  assert_contains "$(cat "${test_dir}/resource-warning.log")" 'installation continued'
)

printf 'PASS: Panda mappings, original zstd archives and atomic resources without Python or jq\n'
