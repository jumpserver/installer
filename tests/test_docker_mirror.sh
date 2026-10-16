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
cp "${TEST_ROOT}/utils/update_docker_versions.py" "${fixture}/utils/"
cp "${TEST_ROOT}/scripts/const.sh" "${fixture}/scripts/"
cp "${TEST_ROOT}/static.env" "${fixture}/"
fixture_sha=$(printf 'mirror fixture\n' | shasum -a 256 | awk '{print $1}')
python3 - "${fixture}/scripts/const.sh" "${fixture_sha}" <<'PY'
from pathlib import Path
import re
import sys
const = Path(sys.argv[1])
const.write_text(re.sub(r'(?<==)[a-f0-9]{64}(?= ;;)', sys.argv[2], const.read_text()))
PY

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

cp "${fixture}/scripts/const.sh" "${test_dir}/original-const.sh"
bash "${fixture}/utils/prepare_docker_mirror.sh" "${test_dir}/new-versions" v30.0.1 2.41.1
bash -n "${test_dir}/new-versions/const.sh"
cmp -s "${fixture}/scripts/const.sh" "${test_dir}/original-const.sh" || fail 'Staging must not change source const.sh'
cp "${test_dir}/new-versions/const.sh" "${fixture}/scripts/const.sh"
(
  unset DOCKER_BIN_HOST DOCKER_IMAGE_MIRROR
  for arch in x86_64 aarch64; do
    export BUILD_ARCH=${arch}
    . "${fixture}/scripts/const.sh"
    assert_eq 30.0.1 "${DOCKER_VERSION}"
    assert_eq v2.41.1 "${DOCKER_COMPOSE_VERSION}"
    assert_eq "${fixture_sha}" "${DOCKER_BIN_SHA256}"
    assert_eq "${fixture_sha}" "${COMPOSE_BIN_SHA256}"
  done
)

# One input preserves the other component and its pinned checksums.
bash "${fixture}/utils/prepare_docker_mirror.sh" "${test_dir}/compose-only" '' v2.42.0
grep -q '^export DOCKER_VERSION=30.0.1$' "${test_dir}/compose-only/const.sh" || fail 'Keep Docker when input is blank'
grep -q '^export DOCKER_COMPOSE_VERSION=v2.42.0$' "${test_dir}/compose-only/const.sh" || fail 'Update Compose'
bash "${fixture}/utils/prepare_docker_mirror.sh" "${test_dir}/docker-only" 30.0.2 ''
grep -q '^export DOCKER_VERSION=30.0.2$' "${test_dir}/docker-only/const.sh" || fail 'Update Docker'
grep -q '^export DOCKER_COMPOSE_VERSION=v2.41.1$' "${test_dir}/docker-only/const.sh" || fail 'Keep Compose when input is blank'
bash "${fixture}/utils/prepare_docker_mirror.sh" "${test_dir}/unchanged" 30.0.1 2.41.1
cmp -s "${fixture}/scripts/const.sh" "${test_dir}/unchanged/const.sh" || fail 'Repeated versions must be a no-op'

cp "${MOCK_CURL_LOG}" "${test_dir}/calls-before-invalid"
if bash "${fixture}/utils/prepare_docker_mirror.sh" "${test_dir}/invalid" '30.0.1; touch unwanted' '' >"${test_dir}/invalid.log" 2>&1; then
  fail 'Malformed version inputs must fail'
fi
cmp -s "${MOCK_CURL_LOG}" "${test_dir}/calls-before-invalid" || fail 'Validate versions before downloading'
assert_contains "$(cat "${test_dir}/invalid.log")" 'Invalid version'

if MOCK_CORRUPT=1 bash "${fixture}/utils/prepare_docker_mirror.sh" "${test_dir}/corrupt-unchanged" '' v2.42.0 >"${test_dir}/corrupt-unchanged.log" 2>&1; then
  fail 'Updating Compose must still verify the unchanged Docker binary'
fi
[[ ! -e "${test_dir}/corrupt-unchanged/const.sh" ]] || fail 'Failed downloads must not generate a candidate'
printf 'tampered\n' >>"${test_dir}/new-versions/linux/static/stable/x86_64/docker-30.0.1.tgz"
rm "${test_dir}/new-versions/const.sh"
if python3 "${fixture}/utils/update_docker_versions.py" "${fixture}/scripts/const.sh" "${test_dir}/new-versions" 30.0.1 v2.41.1 >"${test_dir}/tampered.log" 2>&1; then
  fail 'Candidate generation must reject changed staged files'
fi
[[ ! -e "${test_dir}/new-versions/const.sh" ]] || fail 'Checksum failures must not generate a candidate'
printf 'PASS: optional version inputs, candidate updates, repeat runs and failure isolation\n'
