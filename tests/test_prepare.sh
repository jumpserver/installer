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
