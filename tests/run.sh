#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp_root=$(mktemp -d -t installer-tests.XXXXXX)
trap 'rm -rf "${test_tmp_root}"' EXIT
export TEST_TMP_ROOT="${test_tmp_root}"

for test_file in "${ROOT}"/tests/test_*.sh; do
  [[ "${test_file}" == *test_helper.sh ]] && continue
  printf '\n==> %s\n' "$(basename "${test_file}")"
  bash "${test_file}" || exit 1
done

printf '\nAll tests passed.\n'
