#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/prepare"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"

. "${TEST_ROOT}/scripts/0_prepare.sh"

artifact="${test_dir}/artifact"
printf 'verified artifact\n' >"${artifact}"
expected=$(file_sha256 "${artifact}")
verify_sha256 "${artifact}" "${expected}"
if verify_sha256 "${artifact}" 'invalid' &>/dev/null; then
  fail 'verify_sha256 must reject a checksum mismatch'
fi

printf 'PASS: downloaded artifacts require a matching SHA-256\n'

printf '%s\n' 'USE_XPACK=1' 'NAMESPACE=registry.internal/custom' >"${test_dir}/config.txt"
assert_contains "$(get_offline_image_manifest)" "registry.internal/custom/panda:${VERSION}"
if get_images | grep -q '/panda:' || get_enabled_services | grep -wq panda; then
  fail 'Panda must be bundled without becoming a local runtime service'
fi
printf '%s\n' 'USE_XPACK=0' >"${test_dir}/config.txt"
if get_offline_image_manifest | grep -q '/panda:'; then
  fail 'CE must not include Panda'
fi

(
  . "${TEST_ROOT}/scripts/virtualapp_resources.sh"
  images="${test_dir}/images"
  output="${test_dir}/data with spaces/virtualapp"
  bin_dir="${test_dir}/usr/local/bin"
  mkdir -p "${images}" "${bin_dir}" "${test_dir}/docker-fixture/docker"
  for tool in bash sh cat chmod cp mv rm mkdir mktemp dirname basename uname hostname ln \
    awk sed grep tr tar gzip dd od head tail sort cut wc find cmp stat readlink \
    sha256sum shasum date env tee rmdir; do
    tool_command=$(command -v "${tool}" || true)
    [[ -z "${tool_command}" ]] || ln -s "${tool_command}" "${bin_dir}/${tool}"
  done
  export PATH="${bin_dir}"
  for tool in python python2 python3 jq; do
    if command -v "${tool}" >/dev/null 2>&1; then
      fail "${tool} must be absent from the offline resource test PATH"
    fi
  done

  test_panda_id="sha256:$(printf '%064d' 0 | tr 0 a)"
  test_panda_arch=amd64
  image='registry.internal/custom/panda:v5.0.0-ee'
  archive="${images}/panda:v5.0.0-ee.zst"
  docker_archive="${test_dir}/docker.tar.gz"
  manifest="${output}/manifest.json"
  docker_checksum=''
  docker() {
    printf '%s\n' "$1" >>"${test_dir}/docker-calls"
    case "$1" in
      image)
        [[ -f "${test_dir}/loaded-image" ]] || return 1
        printf '%s %s linux\n' "${test_panda_id}" "${test_panda_arch}"
        ;;
      load) cat >"${test_dir}/loaded-image" ;;
      *) fail "Unexpected Docker operation: $*" ;;
    esac
  }
  prepare_resources() {
    main "${images}" "${docker_archive}" "${output}" "${image}" "${DOCKER_VERSION}" "${1-${docker_checksum}}" \
      >"${test_dir}/resource.log" 2>&1
  }

  prepare_resources
  [[ ! -e "${output}" && ! -e "${test_dir}/docker-calls" ]] || fail 'Online packages must not create offline resources'

  # Preserve a zstd frame containing one uncompressed block; no zstd tool is needed.
  printf '\050\265\057\375\040\023\231\000\000offline Panda image' >"${archive}"
  printf '%s\n' "${test_panda_id}" >"${images}/panda:v5.0.0-ee.sha256"
  # A minimal amd64 ELF header identifies the Docker package without executing it.
  printf '\177ELF\002\001\000\000\000\000\000\000\000\000\000\000\000\000\076\000' \
    >"${test_dir}/docker-fixture/docker/docker"
  tar -czf "${docker_archive}" -C "${test_dir}/docker-fixture" docker/docker
  docker_checksum=$(file_sha256 "${docker_archive}")
  retained="${output}/panda-$(file_sha256 "${archive}").zst"
  prepare_resources
  cmp -s "${archive}" "${test_dir}/loaded-image" || fail 'Docker must load the original zstd bytes'
  cmp -s "${archive}" "${retained}" || fail 'Offline resources must preserve the original zstd bytes'
  cmp -s "${docker_archive}" "${output}/docker-${docker_checksum}.tar.gz" || fail 'Docker archive must be retained'
  cmp -s "${output}/docker.service" "${TEST_ROOT}/scripts/docker/docker.service" || fail 'Use the Installer Docker service'
  assert_contains "$(cat "${manifest}")" "\"image_id\": \"${test_panda_id}\""
  assert_contains "$(cat "${manifest}")" '"architecture": "amd64"'

  ln "${retained}" "${test_dir}/staged-image"
  ln "${manifest}" "${test_dir}/previous-manifest"
  prepare_resources
  assert_eq 1 "$(grep -c '^load$' "${test_dir}/docker-calls")" 'Matching images must not load again'
  [[ "${retained}" -ef "${test_dir}/staged-image" && "${manifest}" -ef "${test_dir}/previous-manifest" ]] ||
    fail 'Repeated preparation must reuse unchanged resources'

  cp "${manifest}" "${test_dir}/previous-manifest-copy"
  if test_panda_arch=arm64 prepare_resources; then
    fail 'Panda and Docker architectures must match'
  fi
  cmp -s "${manifest}" "${test_dir}/previous-manifest-copy" || fail 'Architecture failures must preserve published resources'
  if prepare_resources "$(printf '%064d' 0)"; then
    fail 'Docker archive checksum mismatches must fail'
  fi
  cmp -s "${manifest}" "${test_dir}/previous-manifest-copy" || fail 'Checksum failures must preserve published resources'

  test_panda_id="sha256:$(printf '%064d' 0 | tr 0 b)"
  printf '%s\n' "${test_panda_id}" >"${images}/panda:v5.0.0-ee.sha256"
  printf '\050\265\057\375\040\023\231\000\000updated Panda image' >"${archive}"
  rm "${test_dir}/loaded-image"
  prepare_resources
  [[ ! -e "${retained}" && -s "${test_dir}/staged-image" ]] || fail 'Old archive cleanup must preserve running task links'
  retained="${output}/panda-$(file_sha256 "${archive}").zst"
  cmp -s "${archive}" "${retained}" || fail 'Updated resources must retain the new archive'
  cp "${manifest}" "${test_dir}/previous-manifest-copy"
  rm "${archive}" "${docker_archive}"
  prepare_resources
  cmp -s "${manifest}" "${test_dir}/previous-manifest-copy" || fail 'Online upgrades must preserve offline resources'
)
printf 'PASS: Panda bundling, zstd retention, resource reuse and failed preparation\n'

(
  . "${TEST_ROOT}/scripts/3_load_images.sh"
  IMAGE_DIR="${test_dir}/runtime-images"
  mkdir -p "${IMAGE_DIR}"
  printf 'main image fixture\n' >"${IMAGE_DIR}/core.zst"
  load_image_files() { return "${IMAGE_STEP_FAILED:-0}"; }
  prepare_virtualapp_resources() { touch "${test_dir}/resources-called"; return 1; }
  echo_done() { printf 'installation continued\n'; }
  if IMAGE_STEP_FAILED=1 main >"${test_dir}/load-failed.log" 2>&1; then
    fail 'Main image load failures must still fail installation'
  fi
  [[ ! -e "${test_dir}/resources-called" ]] || fail 'Failed image loading must not prepare resources'
  main >"${test_dir}/resource-warning.log" 2>&1
  assert_contains "$(cat "${test_dir}/resource-warning.log")" '[WARN] Virtual app offline resources could not be prepared'
  assert_contains "$(cat "${test_dir}/resource-warning.log")" 'installation continued'
)
printf 'PASS: resource preparation failures warn without blocking installation\n'
