#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/executor"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"
. "${TEST_ROOT}/scripts/utils.sh"

keys="${test_dir}/keys with spaces"
sh "${TEST_ROOT}/config_init/ansible-executor/init.sh" "${keys}"
client_before=$(cksum "${keys}/client/client")
server_before=$(cksum "${keys}/server/ssh_host_ed25519_key")
sh "${TEST_ROOT}/config_init/ansible-executor/init.sh" "${keys}"
assert_eq "${client_before}" "$(cksum "${keys}/client/client")" 'restarts must retain client identity'
assert_eq "${server_before}" "$(cksum "${keys}/server/ssh_host_ed25519_key")" 'restarts must retain server identity'
assert_eq "$(cat "${keys}/client/client.pub")" "$(cat "${keys}/public/jms-executor.pub")"
assert_eq "[ansible-executor]:2222 $(cat "${keys}/server/ssh_host_ed25519_key.pub")" "$(cat "${keys}/client/known_hosts")"
assert_eq '' "$(find "${keys}" -type f ! -perm 600)" 'credential files must be private'
assert_eq '' "$(find "${keys}" -type d ! -perm 700)" 'credential directories must be private'
rm "${keys}/client/client"
if sh "${TEST_ROOT}/config_init/ansible-executor/init.sh" "${keys}" >"${test_dir}/missing.log" 2>&1; then
  fail 'lost private keys must fail instead of rotating silently'
fi
assert_eq "${server_before}" "$(cksum "${keys}/server/ssh_host_ed25519_key")"
printf 'PASS: independent private keys, pinned host key, restart persistence and lost-key failure\n'

for edition in 0 1; do
  set_config USE_XPACK "${edition}"
  manifest=$(get_offline_image_manifest)
  assert_contains "${manifest}" 'jumpserver/ansible-executor-ssh:latest'
  [[ "${manifest}" != *'/ansible-executor:latest'* ]] || fail 'old executor must not be bundled'
done
set_config NAMESPACE registry.internal/custom
assert_contains "$(get_offline_image_manifest)" 'registry.internal/custom/ansible-executor-ssh:latest'
set_config ANSIBLE_EXECUTOR_ENABLED 0
[[ "$(get_offline_image_manifest)" != *'/ansible-executor-ssh:latest'* ]] || fail 'disabled executor must not be bundled'
[[ "$(get_docker_compose_cmd_line)" != *'compose/ansible-executor.yml'* ]] || fail 'disabled executor must not be deployed'
docker() { fail 'disabled executor must not initialize credentials'; }
prepare_ansible_executor
printf 'PASS: CE/EE image selection, custom namespaces and external executor mode\n'

BUILD_ARCH=${ARCH}
check_image_exists() { echo 1; }
docker() { printf '%s\n' "$*" >>"${test_dir}/pull-calls"; }
pull_image jumpserver/ansible-executor-ssh:latest registry.internal/custom/ansible-executor-ssh:latest >"${test_dir}/pull.log"
assert_contains "$(cat "${test_dir}/pull-calls")" 'pull -q' 'online upgrades must refresh latest even if present'
assert_contains "$(cat "${test_dir}/pull-calls")" 'tag jumpserver/ansible-executor-ssh:latest registry.internal/custom/ansible-executor-ssh:latest'
docker() { return 1; }
if pull_image jumpserver/ansible-executor-ssh:latest >"${test_dir}/pull.log" 2>&1; then
  fail 'failed latest pulls must not silently use the old image'
fi
printf 'PASS: latest refresh, namespace retagging and pull failure propagation\n'
