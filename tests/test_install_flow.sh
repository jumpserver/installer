#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "${TEST_ROOT}/scripts/gists/conf.sh"

test_dir="${TEST_TMP_ROOT}/install-flow"
original_path=${PATH}
export INSTALLER_SOURCE_ROOT="${TEST_ROOT}"
export UNCHECK_DEPENDENCIES=1

# Run the real entry points in disposable installations. Docker, host setup,
# and downloads are replaced at their boundaries; no database is contacted.
function prepare_case() {
  local name=$1
  case_dir="${test_dir}/${name}"
  installer_dir="${case_dir}/opt/jumpserver-installer-regression"
  export JS_CONFIG_DIR="${case_dir}/config"
  export CONFIG_FILE="${JS_CONFIG_DIR}/config.txt"
  export INSTALL_FLOW_EVENTS="${case_dir}/events"
  export FAIL_STAGE=''
  export UPGRADE_STATUS=0
  mkdir -p "${installer_dir}/scripts" "${installer_dir}/compose" "${case_dir}/bin" \
    "${JS_CONFIG_DIR}" "${case_dir}/volume"
  : >"${INSTALL_FLOW_EVENTS}"
  printf '%s\n' \
    'DB_ENGINE=mysql' 'DB_HOST=mysql' 'DB_PORT=3306' 'DB_NAME=jumpserver' \
    'DB_USER=root' 'DB_PASSWORD=legacy-password' \
    'REDIS_HOST=redis' 'REDIS_PORT=6379' 'REDIS_PASSWORD=redis-password' \
    'SECRET_KEY=existing-secret' 'BOOTSTRAP_TOKEN=existing-token' \
    'HTTP_PORT=8080' 'KOKO_SSH_PORT=2222' 'USE_XPACK=0' \
    "VOLUME_DIR=${case_dir}/volume" >"${CONFIG_FILE}"
  printf '# DOCKER_IMAGE_MIRROR=1\n' >"${installer_dir}/config-example.txt"
  cp "${TEST_ROOT}/jmsctl.sh" "${installer_dir}/jmsctl.sh"
  cp "${TEST_ROOT}/scripts/4_install_jumpserver.sh" "${installer_dir}/scripts/"
  cp "${TEST_ROOT}/scripts/1_config_jumpserver.sh" "${installer_dir}/scripts/"
  chmod +x "${installer_dir}/jmsctl.sh"

  cat >"${installer_dir}/scripts/utils.sh" <<'EOF'
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${PROJECT_DIR}/scripts"
SCRIPT_DIR=${BASE_DIR}
CONFIG_DIR=${JS_CONFIG_DIR}
CONFIG_FILE="${CONFIG_DIR}/config.txt"
CONFIG_SAFE_FILE="${CONFIG_DIR}/config_safe.txt"
VERSION=v5.1.0-ce
OS=$(/usr/bin/uname -s)
. "${INSTALLER_SOURCE_ROOT}/scripts/gists/conf.sh"
. "${INSTALLER_SOURCE_ROOT}/scripts/gists/service.sh"
gettext() { printf '%s\n' "$1"; }
echo_logo() { :; }
echo_green() { :; }
echo_yellow() { :; }
echo_check() { :; }
echo_done() { :; }
log_warn() { printf '%s\n' "$*" >&2; }
log_error() { printf '%s\n' "$*" >&2; }
read_from_input() { :; }
random_str() { printf 'generated-%s\n' "$1"; }
get_host_ip() { printf '127.0.0.1\n'; }
set_openbao() { :; }
configure_jdmc() { :; }
record_stage() {
  printf '%s:%s\n' "$1" "$(get_config CURRENT_VERSION)" >>"${INSTALL_FLOW_EVENTS}"
}
prepare_config() { record_stage prepare; }
perform_db_migrations() { record_stage migrations; [[ "${FAIL_STAGE}" != migrations ]]; }
ensure_core_data_symlink() { :; }
ensure_current_installer_link() { :; }
install_jdmc() { record_stage jdmc; [[ "${FAIL_STAGE}" != jdmc ]]; }
installation_log() { record_stage "success-$1"; }
stop_disabled_video_worker() { :; }
prepare_video_worker_volume() { :; }
get_docker_compose_cmd_line() { printf 'docker compose\n'; }
docker() { :; }
start_jdmc() { record_stage start; }
if [[ "${FAIL_STAGE}" == version ]]; then
  set_current_version() { return 1; }
fi
EOF

  cat >"${installer_dir}/scripts/2_install_docker.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/utils.sh"
record_stage docker-prepare
[[ "${FAIL_STAGE}" != docker ]]
EOF
  cat >"${installer_dir}/scripts/3_load_images.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/utils.sh"
record_stage images
[[ "${FAIL_STAGE}" != images ]]
EOF
  cat >"${installer_dir}/scripts/7_upgrade.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/utils.sh"
[[ -L "${PROJECT_DIR}/.env" && "${PROJECT_DIR}/.env" -ef "${CONFIG_FILE}" ]] || exit 97
[[ -L "${PROJECT_DIR}/compose/.env" && "${PROJECT_DIR}/compose/.env" -ef "${CONFIG_FILE}" ]] || exit 97
record_stage upgrade
exit "${UPGRADE_STATUS}"
EOF

  # The bootstrap scripts target Linux and /opt. Keep those operations inside
  # the fixture, including Linux sed's -i spelling when running on macOS.
  cat >"${case_dir}/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux\n'
EOF
  cat >"${case_dir}/bin/sed" <<'EOF'
#!/usr/bin/env bash
if [[ "$(/usr/bin/uname -s)" == Darwin && "${1:-}" == -i && -n "${2:-}" ]]; then
  shift
  exec /usr/bin/sed -i '' "$@"
fi
exec /usr/bin/sed "$@"
EOF
  local tool
  for tool in curl wget tar gettext sha256sum; do
    printf '#!/usr/bin/env bash\nexit 99\n' >"${case_dir}/bin/${tool}"
  done
  chmod +x "${case_dir}"/bin/*
  export PATH="${case_dir}/bin:${original_path}"
}

for quick_script in quick_start.sh cn-quick_start.sh; do
  prepare_case "${quick_script}"
  printf 'CURRENT_VERSION=v5.0.0-ce\n' >>"${CONFIG_FILE}"
  cp "${CONFIG_FILE}" "${case_dir}/original.conf"
  sed "s@/opt@${case_dir}/opt@g" "${TEST_ROOT}/${quick_script}" >"${case_dir}/quick.sh"
  VERSION=regression bash "${case_dir}/quick.sh" >"${case_dir}/output.log" 2>&1
  assert_eq $'upgrade:v5.0.0-ce\nstart:v5.0.0-ce' "$(cat "${INSTALL_FLOW_EVENTS}")" \
    "${quick_script} must upgrade an existing installation before starting it"
  cmp -s "${CONFIG_FILE}" "${case_dir}/original.conf" || fail 'bootstrap must not reconfigure the old installation'
done
printf 'PASS: both bootstrap scripts route existing installations through upgrade\n'

prepare_case failed-upgrade
printf 'CURRENT_VERSION=v5.0.0-ce\n' >>"${CONFIG_FILE}"
cp "${CONFIG_FILE}" "${case_dir}/original.conf"
export UPGRADE_STATUS=23
status=0
bash "${installer_dir}/jmsctl.sh" install >"${case_dir}/output.log" 2>&1 || status=$?
assert_eq 23 "${status}" 'direct install must propagate upgrade failure'
cmp -s "${CONFIG_FILE}" "${case_dir}/original.conf" || fail 'failed upgrade dispatch must preserve the original configuration'
assert_eq 'upgrade:v5.0.0-ce' "$(cat "${INSTALL_FLOW_EVENTS}")" 'failed upgrade must not run installation stages'
printf 'PASS: direct install preserves the old version and credentials on upgrade failure\n'

for db_user in root jumpserver_existing; do
  prepare_case "reconfigure-${db_user}"
  mkdir -p "${case_dir}/volume/mariadb/data"
  set_config DB_USER "${db_user}"
  set_config DB_PORT 4406
  if [[ "${db_user}" != root ]]; then
    set_config MYSQL_ROOT_PASSWORD verified-root-password
  fi
  root_password_before=$(get_config MYSQL_ROOT_PASSWORD)
  for attempt in 1 2; do
    bash "${installer_dir}/scripts/1_config_jumpserver.sh" >"${case_dir}/output.log" 2>&1
    assert_eq "${db_user}" "$(get_config DB_USER)" 'reconfiguration must preserve an existing database user'
    assert_eq legacy-password "$(get_config DB_PASSWORD)" 'reconfiguration must preserve the existing database password'
    assert_eq 4406 "$(get_config DB_PORT)" 'reconfiguration must preserve a custom database port'
    assert_eq "${root_password_before}" "$(get_config MYSQL_ROOT_PASSWORD)" 'reconfiguration must not invent a root password for existing data'
  done
done
printf 'PASS: repeated configuration preserves legacy root and migrated business credentials\n'

prepare_case missing-credentials
mkdir -p "${case_dir}/volume/mysql/data"
set_config DB_PASSWORD ''
if bash "${installer_dir}/scripts/1_config_jumpserver.sh" >"${case_dir}/output.log" 2>&1; then
  fail 'existing database data with incomplete credentials must stop configuration'
fi
assert_eq root "$(get_config DB_USER)" 'incomplete configuration must not replace the existing user'
assert_eq '' "$(get_config DB_PASSWORD)" 'incomplete configuration must not generate a database password'
assert_eq '' "$(get_config MYSQL_ROOT_PASSWORD)" 'incomplete configuration must not generate a root password'
printf 'PASS: incomplete credentials for existing data require recovery instead of replacement\n'

prepare_case new-install
set_config DB_USER ''
set_config DB_PASSWORD ''
bash "${installer_dir}/jmsctl.sh" install >"${case_dir}/output.log" 2>&1
assert_eq jumpserver "$(get_config DB_USER)" 'new installation must still create a business login configuration'
assert_eq generated-26 "$(get_config DB_PASSWORD)" 'new installation must generate its business password'
assert_eq generated-32 "$(get_config MYSQL_ROOT_PASSWORD)" 'new installation must generate its root password'
assert_eq v5.1.0-ce "$(get_config CURRENT_VERSION)" 'successful installation must persist its version'
assert_eq $'prepare:\ndocker-prepare:\nimages:\nmigrations:\njdmc:\nsuccess-install:v5.1.0-ce' \
  "$(cat "${INSTALL_FLOW_EVENTS}")" 'the version must be written only after all installation stages succeed'
printf 'PASS: new installation writes its version only after successful setup\n'

for stage in docker images migrations jdmc version; do
  prepare_case "failed-${stage}"
  export FAIL_STAGE=${stage}
  if bash "${installer_dir}/jmsctl.sh" install >"${case_dir}/output.log" 2>&1; then
    fail "installation must fail when ${stage} fails"
  fi
  assert_eq '' "$(get_config CURRENT_VERSION)" "${stage} failure must not record a completed installation"
  if [[ "$(cat "${INSTALL_FLOW_EVENTS}")" == *success-install* ]]; then
    fail "${stage} failure must not report installation success"
  fi
done
printf 'PASS: installation failures and version-write failures never record success\n'
