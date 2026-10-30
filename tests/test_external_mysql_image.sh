#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/external-mysql-image"
mkdir -p "${test_dir}/volume"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"
. "${TEST_ROOT}/scripts/3_load_images.sh"

set_config VOLUME_DIR "${test_dir}/volume"
set_config DB_ENGINE mysql
set_config DB_HOST db.example.test
set_config DB_IMAGE mariadb:10.6
set_config HA_MODE 0
export USE_XPACK=0 OFFLINE_IMAGE_SERVICES=core
export VAULT_ENABLED=false SSH_CA_ENABLED=false
export IMAGE_PULL_POLICY=Always BUILD_ARCH=x86_64
export SKIP_BACKUP_DB=1

IMAGE_DIR="${test_dir}/images"
mkdir -p "${IMAGE_DIR}"
for test_image in redis:7.4.10-bookworm "jumpserver/core:${VERSION}"; do
  archive_name=${test_image##*/}
  printf 'mock archive\n' >"${IMAGE_DIR}/${archive_name}.zst"
  printf 'sha256:installed\n' >"${IMAGE_DIR}/${archive_name}.sha256"
done

docker_calls="${test_dir}/docker-calls"
installed_db_image=''
fail_pull_image=''
load_result=fail
docker() {
  printf '%s\n' "$*" >>"${docker_calls}"
  case "$1 ${2:-}" in
    'image inspect')
      case "${*: -1}" in
        redis:7.4.10-bookworm|"jumpserver/core:${VERSION}")
          printf 'sha256:installed\n'
          ;;
        *)
          [[ "${*: -1}" == "${installed_db_image}" ]] || return 1
          printf 'sha256:installed\n'
          ;;
      esac
      ;;
    'pull '*) [[ "${*: -1}" != "${fail_pull_image}" ]] ;;
    'tag '*) installed_db_image=$3 ;;
    'load ')
      case "${load_result}" in
        fail) return 1 ;;
        success) installed_db_image=$(get_db_images) ;;
        missing) ;;
      esac
      ;;
    *) fail "Unexpected Docker command: $*" ;;
  esac
}
gettext() { printf '%s\n' "$1"; }
echo_red() { printf '%s\n' "$*"; }
echo_done() { printf 'complete\n'; }
log_warn() { printf 'WARNING: %s\n' "$*"; }

assert_no_db_image_operations() {
  if grep -Eq 'mysql|mariadb' "${docker_calls}"; then
    fail 'external MySQL with backup disabled must not inspect, load, or pull a database image'
  fi
}

for db_image in mariadb:10.6 mysql:8.0; do
  set_config DB_IMAGE "${db_image}"
  assert_eq "${db_image}" "$(get_db_images)" 'backup and restore must still resolve their client image'
  : >"${docker_calls}"
  if ! main >"${test_dir}/load.log"; then
    cat "${test_dir}/load.log"
    fail 'external MySQL with backup disabled must load successfully without a database image'
  fi
  assert_no_db_image_operations
  assert_contains "$(cat "${docker_calls}")" "jumpserver/core:${VERSION}"
done
printf 'PASS: offline loading works without a database image when external MySQL backup is explicitly skipped\n'

# The online path must omit the same database image, even with forced pulling.
IMAGE_DIR="${test_dir}/no-offline-images"
: >"${docker_calls}"
main >"${test_dir}/pull.log"
assert_no_db_image_operations
assert_contains "$(cat "${docker_calls}")" 'pull -q'
assert_contains "$(cat "${docker_calls}")" "core:${VERSION}"
IMAGE_DIR="${test_dir}/images"
printf 'PASS: online loading does not pull the external MySQL backup image\n'

set_config DB_IMAGE mariadb:10.6
assert_db_image_required() {
  local expected_image=$1
  if main >"${test_dir}/load.log"; then
    fail "missing required database image must fail loading: ${expected_image}"
  fi
  assert_contains "$(cat "${test_dir}/load.log")" "Docker image not found: ${IMAGE_DIR}/${expected_image}.zst"
  assert_contains "$(get_pull_images)" "${expected_image}" 'required database images must also remain in the pull list'
}

unset SKIP_BACKUP_DB
assert_db_image_required mariadb:10.6
export SKIP_BACKUP_DB=0
assert_db_image_required mariadb:10.6

# Upgrades tolerate only the external MySQL backup image. The normal loader
# above stays strict, and an explicitly skipped backup still omits the image.
export ALLOW_MISSING_DB_IMAGE=1
for selected_db_image in mariadb:10.6 mysql:8.0; do
  set_config DB_IMAGE "${selected_db_image}"
  unset SKIP_BACKUP_DB
  main >"${test_dir}/load.log"
  assert_contains "$(cat "${test_dir}/load.log")" 'WARNING: Docker image not found'
  assert_contains "$(cat "${test_dir}/load.log")" 'upgrade will continue'

  export SKIP_BACKUP_DB=0
  main >"${test_dir}/load.log"
  assert_contains "$(cat "${test_dir}/load.log")" 'WARNING: Docker image not found'

  for installed_db_image in "${selected_db_image}" "jumpserver/${selected_db_image}"; do
    main >"${test_dir}/load.log"
    assert_eq "${selected_db_image}" "${installed_db_image}" 'legacy client tags must remain usable'
    if [[ "$(cat "${test_dir}/load.log")" == *WARNING* ]]; then
      fail 'an available backup image must not produce a missing-image warning'
    fi
  done
  installed_db_image=''

  printf 'mock archive\n' >"${IMAGE_DIR}/${selected_db_image}.zst"
  main >"${test_dir}/load.log"
  assert_contains "$(cat "${test_dir}/load.log")" 'WARNING: Docker image ID file not found'
  : >"${IMAGE_DIR}/${selected_db_image}.sha256"
  main >"${test_dir}/load.log"
  assert_contains "$(cat "${test_dir}/load.log")" 'WARNING: Docker image ID file is empty'
  printf 'sha256:installed\n' >"${IMAGE_DIR}/${selected_db_image}.sha256"
  main >"${test_dir}/load.log"
  assert_contains "$(cat "${test_dir}/load.log")" 'WARNING: Error loading image'
  load_result=missing
  main >"${test_dir}/load.log"
  assert_contains "$(cat "${test_dir}/load.log")" 'WARNING: Docker image not found after loading'
  load_result=success
  main >"${test_dir}/load.log"
  assert_eq "${selected_db_image}" "${installed_db_image}" 'available archives must still be loaded for backup'
  installed_db_image=''
  load_result=fail
  rm "${IMAGE_DIR}/${selected_db_image}.zst" "${IMAGE_DIR}/${selected_db_image}.sha256"
done
printf 'PASS: upgrades warn for unavailable external MySQL clients and still use local or packaged clients\n'

IMAGE_DIR="${test_dir}/no-offline-images"
fail_pull_image=$(get_db_images)
main >"${test_dir}/pull.log" 2>&1
assert_contains "$(cat "${test_dir}/pull.log")" "WARNING: Failed to pull Docker image: ${fail_pull_image}"
fail_pull_image="jumpserver/core:${VERSION}"
if main >"${test_dir}/pull.log" 2>&1; then
  fail 'application image pull failure must still stop an external MySQL upgrade'
fi
fail_pull_image=''
IMAGE_DIR="${test_dir}/images"
set_config DB_IMAGE mariadb:10.6
printf 'PASS: upgrades tolerate backup-client pull failures but reject application pull failures\n'

export SKIP_BACKUP_DB=1

set_config DB_HOST mysql
assert_db_image_required mariadb:10.6
set_config DB_IMAGE mysql:8.0
assert_db_image_required mysql:8.0
set_config DB_IMAGE mariadb:10.6

set_config DB_HOST db.example.test
set_config HA_MODE 1
assert_db_image_required mariadb:10.6
set_config HA_MODE 0

set_config DB_HOST ''
assert_db_image_required mariadb:10.6
set_config DB_HOST postgresql
assert_db_image_required mariadb:10.6
set_config DB_HOST db.example.test
set_config DB_ENGINE postgresql
assert_db_image_required postgres:16.15-bookworm
printf 'PASS: internal databases, HA, missing hosts, and PostgreSQL retain required image checks during upgrade\n'

# Older MySQL configurations can omit DB_ENGINE.
remove_config DB_ENGINE
: >"${docker_calls}"
main >"${test_dir}/load.log"
assert_no_db_image_operations

rm "${IMAGE_DIR}/core:${VERSION}.zst"
if main >"${test_dir}/load.log"; then
  fail 'skipping the external database backup must not hide a missing application image'
fi
assert_contains "$(cat "${test_dir}/load.log")" "Docker image not found: ${IMAGE_DIR}/core:${VERSION}.zst"
printf 'PASS: legacy external MySQL is supported and missing application images remain fatal\n'
