#!/usr/bin/env bash

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/docker-mirror"
mkdir -p "${test_dir}"

(
  unset DOCKER_BIN_HOST DOCKER_IMAGE_MIRROR
  export BUILD_ARCH=arm64
  . "${TEST_ROOT}/scripts/const.sh"
  docker_path="linux/static/stable/aarch64/docker-${DOCKER_VERSION}.tgz"
  compose_path="docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-aarch64"
  assert_eq "https://download.docker.com/${docker_path}" "${DOCKER_BIN_URL}"
  assert_eq "https://github.com/${compose_path}" "${COMPOSE_BIN_URL}"

  export DOCKER_IMAGE_MIRROR=1
  . "${TEST_ROOT}/scripts/const.sh"
  assert_eq "https://download.jumpserver.org/${docker_path}" "${DOCKER_BIN_URL}"
  assert_eq "https://download.jumpserver.org/${compose_path}" "${COMPOSE_BIN_URL}"
  unset DOCKER_IMAGE_MIRROR
  export DOCKER_BIN_HOST=https://env.example.com
  . "${TEST_ROOT}/scripts/const.sh"
  assert_eq "https://env.example.com/${docker_path}" "${DOCKER_BIN_URL}"
  assert_eq "https://env.example.com/${compose_path}" "${COMPOSE_BIN_URL}"
)
printf 'PASS: const.sh official and mirror URLs, arm64 alias and custom host\n'

# Run the staging script against fixture downloads, including a corrupt response.
fixture="${test_dir}/fixture"
mkdir -p "${fixture}/scripts" "${fixture}/utils" "${test_dir}/bin"
cp "${TEST_ROOT}/utils/prepare_docker_mirror.sh" "${fixture}/utils/"
cp "${TEST_ROOT}/scripts/const.sh" "${fixture}/scripts/"
cp "${TEST_ROOT}/static.env" "${fixture}/"
fixture_sha=$(printf 'mirror fixture\n' | shasum -a 256 | awk '{print $1}')
printf '\nexport DOCKER_BIN_SHA256=%s COMPOSE_BIN_SHA256=%s\n' \
  "${fixture_sha}" "${fixture_sha}" >>"${fixture}/scripts/const.sh"

cat >"${test_dir}/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
target='' url=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) target=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "${url}" in
  https://download.docker.com/*|https://github.com/docker/compose/*) ;;
  *) echo "Unexpected download source: ${url}" >&2; exit 1 ;;
esac
printf '%s\n' "${url}" >>"${MOCK_CURL_LOG}"
if [[ "${MOCK_CORRUPT:-}" == 1 ]]; then
  printf 'corrupt download\n' >"${target}"
else
  printf 'mirror fixture\n' >"${target}"
fi
MOCK
chmod +x "${test_dir}/bin/curl"
export PATH="${test_dir}/bin:${PATH}" MOCK_CURL_LOG="${test_dir}/curl.log"
export DOCKER_BIN_HOST=https://must-not-download.example.com DOCKER_IMAGE_MIRROR=1
bash "${fixture}/utils/prepare_docker_mirror.sh" "${test_dir}/output with spaces"
assert_eq 4 "$(wc -l <"${MOCK_CURL_LOG}" | tr -d ' ')"
assert_eq 12 "$(find "${test_dir}/output with spaces" -type f | wc -l | tr -d ' ')"
(
  . "${TEST_ROOT}/scripts/const.sh"
  for arch in x86_64 aarch64; do
    for relative in "linux/static/stable/${arch}/docker-${DOCKER_VERSION}.tgz" \
      "docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${arch}"; do
      target="${test_dir}/output with spaces/${relative}"
      [[ -f "${target}" && -s "${target}.md5" ]] || fail "Missing staged artifact: ${relative}"
      assert_eq "${fixture_sha}" "$(cat "${target}.sha256")"
    done
  done
)
if MOCK_CORRUPT=1 bash "${fixture}/utils/prepare_docker_mirror.sh" "${test_dir}/bad" >"${test_dir}/bad.log" 2>&1; then
  fail 'Corrupt downloads must stop staging'
fi
assert_contains "$(cat "${test_dir}/bad.log")" 'SHA-256 verification failed'
assert_eq 0 "$(find "${test_dir}/bad" -type f | wc -l | tr -d ' ')"
printf 'PASS: official-source staging, exact OSS paths, checksums and corrupt-download rejection\n'
