#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/conf"
mkdir -p "${test_dir}"
export CONFIG_FILE="${test_dir}/config.txt"
export CONFIG_DIR="${test_dir}"
export CONFIG_SAFE_FILE="${test_dir}/config_safe.txt"
export OS
OS=$(uname -s)

printf '%s\n' \
  'PASSWORD=abc=def' \
  'LABEL=hello world' \
  'REDIS_SENTINEL_HOSTS=old' >"${CONFIG_FILE}"

. "${TEST_ROOT}/scripts/gists/common.sh"
. "${TEST_ROOT}/scripts/gists/conf.sh"

assert_eq 'abc=def' "$(get_config PASSWORD)" 'get_config must preserve equals signs'
assert_eq 'hello world' "$(get_config LABEL)" 'get_config must preserve spaces'

sentinel_hosts='mymaster/10.0.0.1:26379,10.0.0.2:26379'
set_config REDIS_SENTINEL_HOSTS "${sentinel_hosts}"
assert_eq "${sentinel_hosts}" "$(get_config REDIS_SENTINEL_HOSTS)" 'set_config must preserve commas'

special_value='a&b,c=d\path with spaces'
set_config SPECIAL_VALUE "${special_value}"
assert_eq "${special_value}" "$(get_config SPECIAL_VALUE)" 'set_config must preserve special characters'

set_config EMPTY_VALUE ''
assert_eq '1' "$(has_config EMPTY_VALUE)" 'set_config must create explicitly empty values'

printf 'PASS: config round trips complex values\n'

ensure_config_secret CHAT_AI_DELEGATION_SECRET 32
delegation_secret=$(get_config CHAT_AI_DELEGATION_SECRET)
[[ "${delegation_secret}" =~ ^[0-9a-f]{64}$ ]] ||
  fail 'delegation secret must contain 32 bytes encoded as lowercase hex'
ensure_config_secret CHAT_AI_DELEGATION_SECRET 32
assert_eq "${delegation_secret}" "$(get_config CHAT_AI_DELEGATION_SECRET)" 'existing delegation secret must be preserved'

printf 'PASS: config secrets are generated once and preserved\n'
