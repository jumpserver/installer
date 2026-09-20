#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/openbao"
mkdir -p "${test_dir}"
export CONFIG_FILE="${test_dir}/config.txt"
export CONFIG_DIR="${test_dir}"

. "${TEST_ROOT}/scripts/gists/common.sh"
. "${TEST_ROOT}/scripts/gists/conf.sh"
. "${TEST_ROOT}/scripts/gists/openbao.sh"

# Reproduce the root/dmidecode environment that made random_str deterministic.
check_root() { return 0; }
dmidecode() { printf '%s\n' '00000000-0000-0000-0000-000000000001'; }
set_openbao_bootstrap_script() { :; }
set_openbao_server_config() { :; }

printf '%s\n' \
  'VAULT_ENABLED=true' \
  'VAULT_BACKEND=openbao' \
  'SSH_CA_ENABLED=true' \
  'OPENBAO_EXTERNAL=false' >"${CONFIG_FILE}"

set_openbao
kv_token=$(get_config VAULT_OPENBAO_TOKEN)
ssh_token=$(get_config SSH_CA_OPENBAO_TOKEN)
[[ "${kv_token}" =~ ^[0-9a-f]{48}$ && "${ssh_token}" =~ ^[0-9a-f]{48}$ ]] ||
  fail 'OpenBao tokens must contain 24 random bytes encoded as hex'
[[ "${kv_token}" != "${ssh_token}" ]] ||
  fail 'KV and SSH CA tokens must be independent on the same machine'

set_openbao
assert_eq "${kv_token}" "$(get_config VAULT_OPENBAO_TOKEN)" 'existing KV token must be preserved'
assert_eq "${ssh_token}" "$(get_config SSH_CA_OPENBAO_TOKEN)" 'existing SSH token must be preserved'

set_config SSH_CA_OPENBAO_TOKEN "${kv_token}"
set_openbao
assert_eq "${kv_token}" "$(get_config VAULT_OPENBAO_TOKEN)" 'repairing duplicate tokens must preserve KV access'
[[ "$(get_config SSH_CA_OPENBAO_TOKEN)" != "${kv_token}" ]] ||
  fail 'duplicate SSH token must be regenerated independently'

set_config SSH_CA_OPENBAO_TOKEN ''
set_openbao
[[ "$(get_config SSH_CA_OPENBAO_TOKEN)" != "${ssh_token}" ]] ||
  fail 'clearing the SSH token must generate a fresh value'
assert_eq "${kv_token}" "$(get_config VAULT_OPENBAO_TOKEN)" 'SSH token regeneration must preserve KV access'

set_config VAULT_ENABLED false
set_config VAULT_OPENBAO_TOKEN ''
set_config SSH_CA_OPENBAO_TOKEN ''
set_openbao
assert_eq '' "$(get_config VAULT_OPENBAO_TOKEN)" 'SSH-only setup must not create a KV token'
[[ "$(get_config SSH_CA_OPENBAO_TOKEN)" =~ ^[0-9a-f]{48}$ ]] ||
  fail 'SSH-only setup must generate a random SSH token'

random_secret() { return 1; }
set_config SSH_CA_OPENBAO_TOKEN ''
if set_openbao; then
  fail 'setup must fail when secret generation fails'
fi
assert_eq '' "$(get_config SSH_CA_OPENBAO_TOKEN)" 'failed generation must not persist a token'

printf 'PASS: OpenBao tokens are independent, preserved, and regenerated safely\n'
