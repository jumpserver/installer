#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/upgrade"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"

. "${TEST_ROOT}/scripts/7_upgrade.sh" ''

current_version_under_test=v3.10.11
get_config() {
  if [[ "$1" == "CURRENT_VERSION" ]]; then
    printf '%s\n' "${current_version_under_test}"
  else
    printf '%s\n' "${2:-}"
  fi
}
log_error() { :; }
gettext() { printf '%s\n' "$1"; }

verify_upgrade_version
current_version_under_test=v3.10.10
if verify_upgrade_version; then
  fail 'versions below the minimum upgrade version must be rejected'
fi
current_version_under_test=''
if verify_upgrade_version; then
  fail 'an empty current version must be rejected'
fi
printf 'PASS: upgrade version preflight handles boundary values\n'

STATIC_ENV="${test_dir}/static.env"
printf 'export VERSION=old-version\n' >"${STATIC_ENV}"
VERSION=v4.0.0-ce
persist_installer_version
assert_eq 'export VERSION=v4.0.0-ce' "$(<"${STATIC_ENV}")" 'version persistence must be atomic and exact'
printf 'PASS: installer version persistence writes the final version\n'

test_volume_dir="${test_dir}/volume"
mkdir -p "${test_volume_dir}/video/data"
printf 'recording\n' >"${test_volume_dir}/video/data/sample"
get_config() {
  if [[ "$1" == "VOLUME_DIR" ]]; then
    printf '%s\n' "${test_volume_dir}"
  else
    printf '%s\n' "${2:-}"
  fi
}
migrate_data_folder
[[ -f "${test_volume_dir}/video-worker/data/sample" ]] || fail 'video-worker data was not migrated'
[[ -L "${test_volume_dir}/video" ]] || fail 'legacy video data path must remain as a rollback-compatible symlink'
printf 'PASS: video-worker data migration remains rollback compatible\n'
