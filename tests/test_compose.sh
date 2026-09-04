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
if [[ "${default_config}" == *'jms_ai'* ]]; then
  fail 'rendered Compose config must not contain the removed AI service'
fi

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
