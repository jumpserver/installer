#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/upgrade"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"

. "${TEST_ROOT}/scripts/7_upgrade.sh" ''

(
  # Redirect the installer's absolute Docker paths into the fixture.
  bin_dir="${test_dir}/bin"
  BASE_DIR="${test_dir}"
  PROJECT_DIR="${test_dir}"
  mkdir -p "${bin_dir}" "${BASE_DIR}/docker"
  touch "${BASE_DIR}/docker/docker.tar.gz" "${bin_dir}/dockerd"
  printf '#!/bin/sh\necho "Docker version 1.0.0, build old"\n' >"${bin_dir}/docker"
  chmod +x "${bin_dir}/docker"
  eval "$(declare -f upgrade_docker install_docker check_docker_install | sed "s|/usr/local/bin/|${bin_dir}/|g")"
  export PATH="${bin_dir}:${PATH}"
  printf 'echo down >>down-events\nexit "${down_status:-0}"\n' >"${PROJECT_DIR}/jmsctl.sh"
  check_root() { return 0; }
  read_from_input() { confirm="${answer}"; }
  sleep() { :; }
  systemctl() { echo "$*" >>"${test_dir}/stop-events"; return "${stop_status:-0}"; }
  check_docker_start() { :; }
  copy_docker() { echo copied >>"${test_dir}/copies"; }
  answer=n
  upgrade_docker
  [[ ! -e "${test_dir}/copies" ]]
  answer=y
  DOCKER_BIN_SHA256=wrong
  if (upgrade_docker); then fail 'bad Docker package must abort upgrade'; fi
  [[ ! -e "${PROJECT_DIR}/down-events" && ! -e "${test_dir}/stop-events" ]]
  DOCKER_BIN_SHA256=$(file_sha256 "${BASE_DIR}/docker/docker.tar.gz")
  export down_status=1
  if (upgrade_docker); then fail 'failed project shutdown must abort upgrade'; fi
  [[ ! -e "${test_dir}/stop-events" && ! -e "${test_dir}/copies" ]]
  down_status=0
  stop_status=1
  if (upgrade_docker); then fail 'failed Docker shutdown must abort upgrade'; fi
  [[ ! -e "${test_dir}/copies" ]]
  stop_status=0
  upgrade_docker
  assert_eq 'copied' "$(cat "${test_dir}/copies")" 'confirmed upgrade must replace existing Docker binaries once'
)

(
  BASE_DIR="${test_dir}/compose"
  system_dir="${BASE_DIR}/system"
  export DOCKER_CONFIG="${BASE_DIR}/user"
  user_dir="${DOCKER_CONFIG}/cli-plugins"
  mkdir -p "${system_dir}" "${user_dir}" "${BASE_DIR}/docker"
  eval "$(declare -f upgrade_compose check_compose_install | sed -e "s|/usr/local/libexec/docker/cli-plugins|${system_dir}|g")"
  check_root() { return 0; }
  read_from_input() { confirm="${answer}"; }
  docker() {
    local plugin="${user_dir}/docker-compose"
    [[ -f "${plugin}" ]] || plugin="${system_dir}/docker-compose"
    plugin=${extra_plugin:-${plugin}}
    if [[ "$1" == info ]]; then printf '%s\n' "${plugin}"; return; fi
    "${plugin}" "${@:2}"
  }
  write_plugin() {
    printf '#!/bin/sh\necho "%s"\n' "$2" >"$1"
    chmod +x "$1"
  }
  DOCKER_COMPOSE_VERSION=v2.40.3
  write_plugin "${BASE_DIR}/docker/docker-compose" 2.40.3
  check_compose_install
  assert_eq 2.40.3 "$(docker compose version --short)" 'fresh install must install the system plugin'
  write_plugin "${system_dir}/docker-compose" 2.40.30
  check_compose_install
  check_docker_compose
  assert_eq 2.40.30 "$(docker compose version --short)" 'normal install must preserve working Compose'
  chmod -x "${system_dir}/docker-compose"
  if check_compose_install; then fail 'preflight must reject a broken existing plugin'; fi
  chmod +x "${system_dir}/docker-compose"
  extra_plugin="${BASE_DIR}/external-compose"
  write_plugin "${extra_plugin}" 2.39.0
  answer=y
  upgrade_compose
  assert_eq 2.40.30 "$("${system_dir}/docker-compose")" 'external Compose must not trigger a system plugin replacement'
  assert_eq 2.39.0 "$(docker compose version --short)" 'external plugin must remain untouched'
  unset extra_plugin
  answer=n
  upgrade_compose
  assert_eq 2.40.30 "$(docker compose version --short)" 'declining must preserve Compose'
  answer=y
  upgrade_compose
  assert_eq 2.40.3 "$(docker compose version --short)" 'system Compose must be replaced'
  write_plugin "${user_dir}/docker-compose" 2.39.0
  write_plugin "${BASE_DIR}/docker/docker-compose" 2.38.0
  if upgrade_compose; then exit 1; fi
  assert_eq 2.39.0 "$(docker compose version --short)" 'invalid package must preserve active plugin'
  write_plugin "${BASE_DIR}/docker/docker-compose" v2.40.3
  upgrade_compose
  assert_eq v2.40.3 "$(docker compose version --short)" 'user plugin takes precedence over system plugin'
  read_from_input() { exit 1; }
  upgrade_compose
)

check_root() { return 1; }
docker() {
  [[ "${1:-}" == "ps" ]]
}
remove_config KOKO_WEB_PROXY_PORT
remove_config WEB_PROXY_ALLOWED_HOSTS
VERSION=v4.0.0-ce
upgrade_config
assert_eq '5001' "$(get_config KOKO_WEB_PROXY_PORT)" 'upgrade must add the default Koko Web Proxy port'
assert_eq 'localhost,127.0.0.1' "$(get_config WEB_PROXY_ALLOWED_HOSTS)" 'upgrade must add the safe Web Proxy allowlist'
set_config KOKO_WEB_PROXY_PORT 15001
set_config WEB_PROXY_ALLOWED_HOSTS 'example.com,*.example.org,localhost,127.0.0.1'
upgrade_config
assert_eq '15001' "$(get_config KOKO_WEB_PROXY_PORT)" 'upgrade must preserve a custom Koko Web Proxy port'
assert_eq 'example.com,*.example.org,localhost,127.0.0.1' "$(get_config WEB_PROXY_ALLOWED_HOSTS)" 'upgrade must preserve a custom Web Proxy allowlist'
printf 'PASS: upgrade adds and preserves Koko Web Proxy configuration\n'

(
  docker_calls="${test_dir}/obsolete-docker-calls"
  mock_container_names=$'jms_lion\njms_facelive\njms_panda\njms_xrdp\njms_lion_backup\njms_core\njms_postgresql'
  fail_action=''
  docker() {
    printf '%s\n' "$*" >>"${docker_calls}"
    case "$1" in
      ps) printf '%s\n' "${mock_container_names}" ;;
      stop|rm) [[ "$*" != "${fail_action}" ]] ;;
      *) return 1 ;;
    esac
  }
  export USE_XPACK=1 XRDP_ENABLED=0
  remove_obsolete_containers
  expected_calls=$'ps -a --format {{.Names}}\nstop jms_lion\nrm jms_lion\nstop jms_facelive\nrm jms_facelive\nstop jms_panda\nrm jms_panda\nstop jms_xrdp\nrm jms_xrdp'
  assert_eq "${expected_calls}" "$(cat "${docker_calls}")" 'cleanup must remove only exact obsolete container names'

  mock_container_names=jms_xrdp
  XRDP_ENABLED=1
  : >"${docker_calls}"
  remove_obsolete_containers
  assert_eq 'ps -a --format {{.Names}}' "$(cat "${docker_calls}")" 'explicitly enabled enterprise XRDP must be preserved'
  USE_XPACK=0
  : >"${docker_calls}"
  remove_obsolete_containers
  assert_contains "$(cat "${docker_calls}")" 'rm jms_xrdp' 'XRDP must be removed outside the enterprise edition'

  mock_container_names=''
  : >"${docker_calls}"
  remove_obsolete_containers
  assert_eq 'ps -a --format {{.Names}}' "$(cat "${docker_calls}")" 'cleanup must succeed when obsolete containers are already absent'

  mock_container_names=jms_lion
  for fail_action in 'stop jms_lion' 'rm jms_lion'; do
    if remove_obsolete_containers; then
      fail "cleanup must propagate failure: ${fail_action}"
    fi
  done
  docker() { return 1; }
  if remove_obsolete_containers; then
    fail 'cleanup must propagate Docker listing failure'
  fi
)
printf 'PASS: upgrade cleans obsolete containers and preserves enabled XRDP\n'

current_version_under_test=v3.10.11
get_config() {
  if [[ "$1" == "CURRENT_VERSION" ]]; then
    printf '%s\n' "${current_version_under_test}"
  else
    printf '%s\n' "${2:-}"
  fi
}
log_error() { :; }
gettext() { printf '%s\n' "$1"; }

verify_upgrade_version
current_version_under_test=v3.10.10
if verify_upgrade_version; then
  fail 'versions below the minimum upgrade version must be rejected'
fi
current_version_under_test=''
if verify_upgrade_version; then
  fail 'an empty current version must be rejected'
fi
printf 'PASS: upgrade version preflight handles boundary values\n'

STATIC_ENV="${test_dir}/static.env"
printf 'export VERSION=old-version\n' >"${STATIC_ENV}"
VERSION=v4.0.0-ce
persist_installer_version
assert_eq 'export VERSION=v4.0.0-ce' "$(<"${STATIC_ENV}")" 'version persistence must be atomic and exact'
printf 'PASS: installer version persistence writes the final version\n'

test_volume_dir="${test_dir}/volume"
mkdir -p "${test_volume_dir}/video/data"
printf 'recording\n' >"${test_volume_dir}/video/data/sample"
get_config() {
  if [[ "$1" == "VOLUME_DIR" ]]; then
    printf '%s\n' "${test_volume_dir}"
  else
    printf '%s\n' "${2:-}"
  fi
}
migrate_data_folder
[[ -f "${test_volume_dir}/video-worker/data/sample" ]] || fail 'video-worker data was not migrated'
[[ -L "${test_volume_dir}/video" ]] || fail 'legacy video data path must remain as a rollback-compatible symlink'
printf 'PASS: video-worker data migration remains rollback compatible\n'
