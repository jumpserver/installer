#!/usr/bin/env bash

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_ROOT="${TEST_TMP_ROOT:-$(mktemp -d -t installer-tests.XXXXXX)}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected=$1 actual=$2 message=${3:-}
  [[ "${actual}" == "${expected}" ]] ||
    fail "${message:-values differ}: expected <${expected}>, got <${actual}>"
}

assert_contains() {
  local haystack=$1 needle=$2 message=${3:-}
  [[ "${haystack}" == *"${needle}"* ]] ||
    fail "${message:-value does not contain expected text}: <${needle}>"
}

