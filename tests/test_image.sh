#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/image"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"
. "${TEST_ROOT}/scripts/3_load_images.sh"

IMAGE_DIR="${test_dir}/images"
mkdir -p "${IMAGE_DIR}"
set_config VOLUME_DIR "${test_dir}/volume"
assert_eq 'postgres:16.15-bookworm' "$(get_db_images)" 'new installations must default to PostgreSQL'

set_config DB_ENGINE mysql
set_config DB_HOST mysql
mkdir -p "${test_dir}/volume/mariadb/data"
assert_eq 'mariadb:10.6' "$(get_db_images)" 'existing MariaDB must retain its image'
assert_eq 'compose/mariadb.yml -f compose/mysql.port.yml' "$(get_db_images_file)" 'existing MariaDB must retain its compose file'
remove_config DB_ENGINE
assert_eq 'mariadb:10.6' "$(get_db_images)" 'legacy configurations without DB_ENGINE must retain MariaDB'
mkdir -p "${test_dir}/volume/mysql/data"
assert_eq 'mysql:8.0' "$(get_db_images)" 'existing MySQL must retain its image'
assert_eq 'compose/mysql.yml -f compose/mysql.port.yml' "$(get_db_images_file)" 'existing MySQL must retain its compose file'
printf 'PASS: database selection preserves PostgreSQL defaults and legacy databases\n'

docker_calls="${test_dir}/docker-calls"
installed_image=''
fail_tag=0
fail_load=0
mock_image_id='sha256:installed'
docker() {
  printf '%s\n' "$*" >>"${docker_calls}"
  case "$1 ${2:-}" in
    'image inspect')
      [[ "${*: -1}" == "${installed_image}" ]] || return 1
      printf '%s\n' "${mock_image_id}"
      ;;
    'tag jumpserver/'*)
      [[ "${fail_tag}" == 0 ]] || return 1
      installed_image=$3
      ;;
    *)
      if [[ "$1" == load ]]; then
        [[ "${fail_load}" == 0 ]] || return 1
        installed_image=${test_image}
      else
        fail "Unexpected Docker command: $*"
      fi
      ;;
  esac
}
get_images() { printf '%s\n' "${test_image}"; }
gettext() { printf '%s\n' "$1"; }
echo_red() { printf '%s\n' "$*"; }

for test_image in mysql:8.0 mariadb:10.6; do
  installed_image=${test_image}
  : >"${docker_calls}"
  load_image_files >"${test_dir}/load.log"
  assert_eq "image inspect ${test_image}" "$(cat "${docker_calls}")" 'existing database images must not require offline archives or ID files'

  installed_image="jumpserver/${test_image}"
  : >"${docker_calls}"
  load_image_files >"${test_dir}/load.log"
  assert_eq "${test_image}" "${installed_image}" 'legacy database tags must be made available to Compose before loading finishes'
  assert_contains "$(cat "${docker_calls}")" "tag jumpserver/${test_image} ${test_image}"

  installed_image="jumpserver/${test_image}"
  fail_tag=1
  if load_image_files >"${test_dir}/load.log"; then
    fail 'failed legacy retagging must fail image loading'
  fi
  fail_tag=0

  installed_image=''
  if load_image_files >"${test_dir}/load.log"; then
    fail 'a missing database image and archive must fail image loading'
  fi
  assert_contains "$(cat "${test_dir}/load.log")" 'Docker image not found'
done
printf 'PASS: offline upgrades reuse local MySQL/MariaDB images and legacy tags\n'

for test_image in postgres:16.15-bookworm jumpserver/core:test; do
  installed_image=${test_image}
  if load_image_files >"${test_dir}/load.log"; then
    fail 'non-legacy images must still require their packaged archives'
  fi
done
printf 'PASS: missing archives remain fatal for other images\n'

test_image=mysql:8.0
installed_image=${test_image}
# A bundled database archive remains authoritative, including Windows filenames.
touch "${IMAGE_DIR}/mysql_8.0.zst"
if load_image_files >"${test_dir}/load.log"; then
  fail 'bundled database archives must still require an image ID file'
fi
printf '%s\n' 'sha256:packaged' >"${IMAGE_DIR}/mysql:8.0.sha256"
: >"${docker_calls}"
load_image_files >"${test_dir}/load.log"
assert_contains "$(cat "${docker_calls}")" 'load' 'a different packaged image must still be loaded'
fail_load=1
if load_image_files >"${test_dir}/load.log"; then
  fail 'failed loading of a packaged database image must not fall back to an old local image'
fi
fail_load=0
mock_image_id='sha256:packaged'
: >"${docker_calls}"
load_image_files >"${test_dir}/load.log"
assert_eq 'image inspect -f {{.ID}} mysql:8.0' "$(cat "${docker_calls}")" 'matching packaged image IDs must still skip loading'
printf 'PASS: bundled database images retain validation and load failure handling\n'
