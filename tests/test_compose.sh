#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

if ! docker compose version &>/dev/null; then
  printf 'SKIP: Docker Compose is unavailable\n'
  exit 0
fi

test_dir="${TEST_TMP_ROOT}/compose"
export HOSTNAME=test-host
export CHAT_AI_DELEGATION_SECRET=test-only-delegation-secret-00000000000000000000000000000000
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
assert_contains "${default_config}" "PLATFORM_DELEGATION_KEY: ${CHAT_AI_DELEGATION_SECRET}" 'Kael must receive the Core delegation secret'
assert_contains "${default_config}" 'published: "5001"' 'Koko Web Proxy must publish the configured external port'
assert_contains "${default_config}" 'target: 5001' 'Koko Web Proxy must use container port 5001'
assert_contains "${default_config}" 'WEB_PROXY_BIND_HOST: 0.0.0.0' 'Koko Web Proxy must listen on the container network'
assert_contains "${default_config}" 'VIDEO_WORKER_HOST: http://video-worker:9000' 'KoKo must use the actual worker Compose service name'
if [[ "${default_config}" == *'jms_ai'* ]]; then
  fail 'rendered Compose config must not contain the removed AI service'
fi

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
