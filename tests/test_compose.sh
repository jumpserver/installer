#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

if ! docker compose version &>/dev/null; then
  printf 'SKIP: Docker Compose is unavailable\n'
  exit 0
fi

test_dir="${TEST_TMP_ROOT}/compose"
export HOSTNAME=test-host
mkdir -p "${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config_safe.txt"

default_config=$(
  cd "${TEST_ROOT}"
  export JS_CONFIG_DIR="${test_dir}"
  . ./scripts/utils.sh
  compose_cmd=$(get_docker_compose_cmd_line)
  assert_contains "${compose_cmd}" 'compose/kael.yml' 'default Compose command must include Kael'
  if [[ "${compose_cmd}" == *'compose/ai.yml'* ]]; then
    fail 'default Compose command must not include the removed AI service'
  fi
  ${compose_cmd} --env-file "${CONFIG_FILE}" config
)
assert_contains "${default_config}" 'jms_kael' 'rendered Compose config must contain Kael'
assert_contains "${default_config}" 'published: "5001"' 'Koko Web Proxy must publish the configured external port'
assert_contains "${default_config}" 'target: 5001' 'Koko Web Proxy must use container port 5001'
assert_contains "${default_config}" 'WEB_PROXY_BIND_HOST: 0.0.0.0' 'Koko Web Proxy must listen on the container network'
assert_contains "${default_config}" 'VIDEO_WORKER_HOST: http://video-worker:9000' 'KoKo must use the actual worker Compose service name'
if [[ "${default_config}" == *'jms_ai'* ]]; then
  fail 'rendered Compose config must not contain the removed AI service'
fi

ce_dir="${TEST_TMP_ROOT}/compose-ce"
mkdir -p "${ce_dir}"
cp "${TEST_ROOT}/config-example.txt" "${ce_dir}/config.txt"
printf '%s\n' \
  'USE_XPACK=0' \
  'ENABLE_VIDEO_WORKER=true' \
  'VIDEO_WORKER_HOST=http://external-worker.example:9000' >>"${ce_dir}/config.txt"
ce_config=$(
  cd "${TEST_ROOT}"
  export JS_CONFIG_DIR="${ce_dir}"
  . ./scripts/utils.sh
  gen_safe_config >/dev/null
  compose_cmd=$(get_docker_compose_cmd_line)
  if [[ "${compose_cmd}" == *'compose/video-worker.yml'* ]]; then
    fail 'CE must exclude the local worker Compose service'
  fi
  ${compose_cmd} --env-file "${CONFIG_FILE}" config
)
assert_contains "${ce_config}" 'ENABLE_VIDEO_WORKER: "false"' 'CE must disable KoKo worker submission even if the source config enables it'
if [[ "${ce_config}" == *'jms_video-worker'* ]]; then
  fail 'CE must not include a local video-worker container'
fi
printf 'PASS: CE excludes video-worker and disables KoKo submission\n'

custom_web_proxy_config=$(
  cd "${TEST_ROOT}"
  export JS_CONFIG_DIR="${test_dir}"
  export KOKO_WEB_PROXY_PORT=15001
  . ./scripts/utils.sh
  compose_cmd=$(get_docker_compose_cmd_line)
  ${compose_cmd} --env-file "${CONFIG_FILE}" config
)
assert_contains "${custom_web_proxy_config}" 'published: "15001"' 'KOKO_WEB_PROXY_PORT must override the published Web Proxy port'

printf '%s\n' \
  'USE_XPACK=1' \
  'USE_ES=1' \
  'USE_MINIO=1' \
  'USE_LOKI=1' \
  'VAULT_ENABLED=true' \
  'SSH_CA_ENABLED=true' >>"${test_dir}/config.txt"
cp "${test_dir}/config.txt" "${test_dir}/config_safe.txt"

all_features_config=$(
  cd "${TEST_ROOT}"
  export JS_CONFIG_DIR="${test_dir}"
  . ./scripts/utils.sh
  compose_cmd=$(get_docker_compose_cmd_line)
  assert_contains "${compose_cmd}" 'compose/video-worker.yml'
  ${compose_cmd} --env-file "${CONFIG_FILE}" config
)
assert_contains "${all_features_config}" 'jms_video-worker' 'rendered compose config must contain video-worker'

offline_manifest=$(
  cd "${TEST_ROOT}"
  export JS_CONFIG_DIR="${test_dir}"
  . ./scripts/utils.sh
  get_offline_image_manifest
)
assert_contains "${offline_manifest}" 'jumpserver/kael:' 'offline manifest must contain the Kael image'
for optional_image in elasticsearch minio grafana/loki grafana/promtail; do
  if [[ "${offline_manifest}" == *"${optional_image}"* ]]; then
    fail "optional image must not be included in the offline manifest: ${optional_image}"
  fi
done

for use_ipv6 in 0 1; do
(
  cd "${TEST_ROOT}"
  export JS_CONFIG_DIR="${ce_dir}"
  . ./scripts/utils.sh
  set_config USE_IPV6 "${use_ipv6}"
  compose_cmd=$(get_docker_compose_cmd_line)
  ${compose_cmd} --env-file "${CONFIG_FILE}" config --format json >"${test_dir}/executor-compose.json"
)
python3 - "${test_dir}/executor-compose.json" "${use_ipv6}" <<'PYTEST'
import json
import sys
config = json.load(open(sys.argv[1]))
services = config['services']
assert bool(config['networks']['executor'].get('enable_ipv6')) == bool(int(sys.argv[2]))
assert bool(config['networks']['net'].get('enable_ipv6')) == bool(int(sys.argv[2]))
for name in ('core', 'celery'):
    service = services[name]
    assert not service.get('privileged'), name
    assert all('docker.sock' not in v['source'] for v in service['volumes']), name
    env = service['environment']
    assert 'ANSIBLE_EXECUTION_BACKEND' not in env
    assert 'ANSIBLE_DOCKER_ENABLED' not in env
    assert env['ANSIBLE_EXECUTOR_HOST'] == 'ansible-executor'
    assert env['ANSIBLE_EXECUTOR_GATEWAY_HOST'] == name
    assert set(service['networks']) == {'net', 'executor'}
    assert service['networks']['net']['gw_priority'] == 1
    credential_mount = next(v for v in service['volumes'] if v['target'] == '/run/jms-executor')
    assert credential_mount['read_only']
executor = services['ansible-executor']
assert set(executor['networks']) == {'executor'}
for name, service in services.items():
    if name not in ('core', 'celery', 'ansible-executor'):
        assert 'executor' not in service.get('networks', {}), name
assert executor['image'].endswith('/ansible-executor-ssh:latest')
assert executor['pull_policy'] == 'never'
assert not executor.get('privileged') and not executor.get('ports')
assert 'no-new-privileges:true' in executor['security_opt']
assert int(executor['mem_limit']) > 0 and int(executor['pids_limit']) > 0
assert '/home/jms-executor:exec,nosuid,nodev' in executor['tmpfs']
assert all('/client' not in v['source'] and 'docker.sock' not in v['source'] for v in executor['volumes'])
assert {v['target'] for v in executor['volumes']} == {'/run/secrets', '/var/lib/jms-executor'}
PYTEST
done
(
  cd "${TEST_ROOT}"
  export JS_CONFIG_DIR="${ce_dir}"
  . ./scripts/utils.sh
  set_config ANSIBLE_DOCKER_ENABLED false
  compose_cmd=$(get_docker_compose_cmd_line)
  ${compose_cmd} --env-file "${CONFIG_FILE}" config --format json >"${test_dir}/native-ansible.json"
  set_config ANSIBLE_DOCKER_ENABLED ''
)
python3 - "${test_dir}/native-ansible.json" <<'PYTEST'
import json
import sys
services = json.load(open(sys.argv[1]))['services']
for name in ('core', 'celery'):
    env = services[name]['environment']
    assert env['ANSIBLE_DOCKER_ENABLED'] == 'false'
    assert 'ANSIBLE_EXECUTION_BACKEND' not in env
assert 'ansible-executor' in services
PYTEST
printf 'PASS: existing Ansible isolation setting is passed through without forcing SSH\n'

(
  cd "${TEST_ROOT}"
  export JS_CONFIG_DIR="${ce_dir}"
  . ./scripts/utils.sh
  set_config ANSIBLE_EXECUTOR_ENABLED 0
  set_config ANSIBLE_EXECUTOR_HOST remote-executor.example
  set_config ANSIBLE_EXECUTOR_GATEWAY_HOST celery.example
  set_config ANSIBLE_EXECUTOR_CORE_GATEWAY_HOST core.example
  compose_cmd=$(get_docker_compose_cmd_line)
  ${compose_cmd} --env-file "${CONFIG_FILE}" config --format json >"${test_dir}/external-executor.json"
)
python3 - "${test_dir}/external-executor.json" <<'PYTEST'
import json
import sys
services = json.load(open(sys.argv[1]))['services']
assert 'ansible-executor' not in services
for name in ('core', 'celery'):
    env = services[name]['environment']
    assert env['ANSIBLE_EXECUTOR_HOST'] == 'remote-executor.example'
    assert env['ANSIBLE_EXECUTOR_GATEWAY_HOST'] == name + '.example'
PYTEST
printf 'PASS: separate caller networks and tunnel addresses in IPv4, IPv6 and external-executor configurations\n'

printf 'PASS: default and all-feature Compose configurations render\n'
printf 'PASS: optional infrastructure images stay out of the offline manifest\n'

printf '%s\n' \
  'VIDEO_WORKER_ENABLED=0' \
  'ENABLE_VIDEO_WORKER=true' \
  'VIDEO_WORKER_HOST=http://external-worker.example:9000' >>"${test_dir}/config.txt"
cp "${test_dir}/config.txt" "${test_dir}/config_safe.txt"
external_worker_config=$(
  cd "${TEST_ROOT}"
  export JS_CONFIG_DIR="${test_dir}"
  . ./scripts/utils.sh
  gen_safe_config >/dev/null
  compose_cmd=$(get_docker_compose_cmd_line)
  if [[ "${compose_cmd}" == *'compose/video-worker.yml'* ]]; then
    fail 'VIDEO_WORKER_ENABLED=0 must exclude the local worker Compose service'
  fi
  ${compose_cmd} --env-file "${CONFIG_FILE}" config
)
assert_contains "${external_worker_config}" 'ENABLE_VIDEO_WORKER: "true"' 'KoKo must receive the worker submission switch'
assert_contains "${external_worker_config}" 'VIDEO_WORKER_HOST: http://external-worker.example:9000' 'KoKo must receive the external worker URL'
if [[ "${external_worker_config}" == *'jms_video-worker'* ]]; then
  fail 'disabled local worker must not appear in Compose configuration'
fi
external_worker_manifest=$(
  cd "${TEST_ROOT}"
  export JS_CONFIG_DIR="${test_dir}"
  . ./scripts/utils.sh
  get_offline_image_manifest
)
if [[ "${external_worker_manifest}" == *'/video-worker:'* ]]; then
  fail 'disabled local worker must not be packed into the offline image manifest'
fi
printf 'PASS: external worker routing disables only the local container and image\n'
