#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/upgrade-backup"
mkdir -p "${test_dir}/volume" "${test_dir}/scripts"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"
. "${TEST_ROOT}/scripts/7_upgrade.sh" ''

set_config VOLUME_DIR "${test_dir}/volume"
set_config DB_HOST db.example.test
set_config HA_MODE 0
unset SKIP_BACKUP_DB
export AUTO_INSTALL=0
SCRIPT_DIR="${test_dir}/scripts"
export BACKUP_EVENTS="${test_dir}/events" BACKUP_RESULT=0
cat >"${SCRIPT_DIR}/5_db_backup.sh" <<'EOF'
#!/usr/bin/env bash
printf 'backup\n' >>"${BACKUP_EVENTS}"
if [[ "${BACKUP_RESULT}" != 0 ]]; then
  printf 'database backup failed (including client/server version mismatch)\n' >&2
fi
exit "${BACKUP_RESULT}"
EOF

installed_db_image=''
docker() {
  case "$1 ${2:-}" in
    'image inspect')
      case "${*: -1}" in
        redis:7.4.10-bookworm|"jumpserver/core:${VERSION}"|"jumpserver/jdmc:${VERSION}") printf 'sha256:installed\n' ;;
        *) [[ "${*: -1}" == "${installed_db_image}" ]] ;;
      esac
      ;;
    'tag '*) installed_db_image=$3 ;;
    *) fail "Unexpected Docker command: $*" ;;
  esac
}
gettext() { printf '%s\n' "$1"; }
log_warn() { printf 'WARNING: %s\n' "$*"; }

select_database() {
  case "$1" in
    postgres:*) set_config DB_ENGINE postgresql ;;
    *) set_config DB_ENGINE mysql; set_config DB_IMAGE "$1" ;;
  esac
}

assert_backup_choices() {
  local expected_events=$1 response status expected_status
  for response in y Y '' n N invalid; do
    : >"${BACKUP_EVENTS}"
    status=0
    (backup_db) <<<"${response}" >"${test_dir}/backup.log" 2>&1 || status=$?
    case "${response}" in y|Y|'') expected_status=0 ;; *) expected_status=1 ;; esac
    assert_eq "${expected_status}" "${status}" "backup confirmation must honor <${response}>"
    assert_eq "${expected_events}" "$(cat "${BACKUP_EVENTS}")"
    assert_contains "$(cat "${test_dir}/backup.log")" 'No successful installer database backup was created'
    assert_contains "$(cat "${test_dir}/backup.log")" 'Continue to upgrade? [Y/n] (Timeout: 30s, default: y)'
  done
  if (backup_db) </dev/null >"${test_dir}/backup.log" 2>&1; then
    fail 'closed input must not be treated as a timeout or approval'
  fi
}

for selected_db_image in mariadb:10.6 mysql:8.0 postgres:16.15-bookworm; do
  select_database "${selected_db_image}"
  installed_db_image=''
  assert_backup_choices ''
  assert_contains "$(cat "${test_dir}/backup.log")" "External database backup image ${selected_db_image} is unavailable"

  installed_db_image=${selected_db_image}
  BACKUP_RESULT=0
  : >"${BACKUP_EVENTS}"
  backup_db </dev/null >"${test_dir}/backup.log"
  assert_eq backup "$(cat "${BACKUP_EVENTS}")" 'available clients must still attempt a backup'
  assert_eq '' "$(cat "${test_dir}/backup.log")" 'successful backups must not prompt'
  if [[ "${selected_db_image}" != postgres:* ]]; then
    installed_db_image="jumpserver/${selected_db_image}"
    backup_db </dev/null >"${test_dir}/backup.log"
    assert_eq "${selected_db_image}" "${installed_db_image}" 'legacy client tags must be reusable'
  fi

  BACKUP_RESULT=1
  assert_backup_choices backup
done
printf 'PASS: external MySQL and PostgreSQL missing clients and backup failures offer explicit timed confirmation\n'

select_database mariadb:10.6
installed_db_image=mariadb:10.6
remove_config DB_ENGINE
(backup_db) <<<y >"${test_dir}/backup.log" 2>&1
assert_contains "$(cat "${test_dir}/backup.log")" 'Continue to upgrade?'
export SKIP_BACKUP_DB=1
: >"${BACKUP_EVENTS}"
backup_db </dev/null >"${test_dir}/backup.log"
assert_eq '' "$(cat "${BACKUP_EVENTS}")" 'explicitly skipped backups must not be attempted'
assert_contains "$(cat "${test_dir}/backup.log")" 'Skip database backup'
unset SKIP_BACKUP_DB
printf 'PASS: legacy MySQL configurations and explicit backup skipping remain supported\n'

# The same confirmation applies to built-in databases and HA backup failures.
for selected_db_image in mariadb:10.6 postgres:16.15-bookworm; do
  select_database "${selected_db_image}"
  for deployment in internal ha; do
    set_config HA_MODE 0
    set_config DB_HOST "$(get_config DB_ENGINE)"
    if [[ "${deployment}" == ha ]]; then
      set_config DB_HOST db.example.test
      set_config HA_MODE 1
    fi
    assert_backup_choices backup
  done
done
printf 'PASS: built-in and HA database backup failures use the same confirmation\n'

# Exercise the real upgrade entry point, input handler, and image loader together.
# Host changes and database operations are mocked at their boundaries.
export UPGRADE_TEST_ROOT="${TEST_ROOT}" UPGRADE_TEST_IMAGES="${test_dir}/images"
export installed_db_image
export -f docker gettext fail
mkdir -p "${UPGRADE_TEST_IMAGES}"
for test_image in redis:7.4.10-bookworm "jumpserver/core:${VERSION}"; do
  archive_name=${test_image##*/}
  printf 'mock archive\n' >"${UPGRADE_TEST_IMAGES}/${archive_name}.zst"
  printf 'sha256:installed\n' >"${UPGRADE_TEST_IMAGES}/${archive_name}.sha256"
done
cat >"${SCRIPT_DIR}/3_load_images.sh" <<'EOF'
#!/usr/bin/env bash
. "${UPGRADE_TEST_ROOT}/scripts/3_load_images.sh"
IMAGE_DIR=${UPGRADE_TEST_IMAGES}
main
EOF
export USE_XPACK=0 OFFLINE_IMAGE_SERVICES=core
export VAULT_ENABLED=false SSH_CA_ENABLED=false
set_config DB_HOST db.example.test
set_config HA_MODE 0
PROJECT_DIR=${test_dir}
BASE_DIR=${SCRIPT_DIR}
write_upgrade_recovery_state() { :; }
check_compose_install() { :; }
backup_config() { :; }
update_config_if_need() { :; }
configure_jdmc() { :; }
db_migrations() { printf 'migrations\n' >>"${BACKUP_EVENTS}"; }
upgrade_docker() { :; }
upgrade_compose() { :; }
ensure_current_installer_link() { :; }
upgrade_jdmc() { :; }
persist_installer_version() { :; }
installation_log() { printf 'success\n' >>"${BACKUP_EVENTS}"; }
clean_images() { :; }

for selected_db_image in mariadb:10.6 postgres:16.15-bookworm; do
  select_database "${selected_db_image}"
  for installed_db_image in '' "${selected_db_image}"; do
    for response in y n; do
      set_config CURRENT_VERSION v3.10.21
      : >"${BACKUP_EVENTS}"
      status=0
      (main) <<EOF >"${test_dir}/upgrade.log" 2>&1 || status=$?
y
${response}
EOF
      expected_events=''
      [[ -z "${installed_db_image}" ]] || expected_events=$'backup\n'
      if [[ "${response}" == y ]]; then
        assert_eq 0 "${status}"
        expected_events+=$'migrations\nsuccess'
        assert_eq "${VERSION}" "$(get_config CURRENT_VERSION)"
      else
        assert_eq 1 "${status}"
        assert_eq v3.10.21 "$(get_config CURRENT_VERSION)" 'declining must not commit the upgrade'
      fi
      assert_eq "${expected_events%$'\n'}" "$(cat "${BACKUP_EVENTS}")"
      assert_contains "$(cat "${test_dir}/upgrade.log")" 'Continue to upgrade? [Y/n]'
    done
  done
done
printf 'PASS: actual upgrades migrate only after accepting failed backup confirmation\n'

# Keep stdin open with no answer to exercise the actual 30-second timeout.
mkfifo "${test_dir}/input"
exec 3<>"${test_dir}/input"
printf 'y\n' >&3
installed_db_image=''
: >"${BACKUP_EVENTS}"
timeout_started=${SECONDS}
(main) <&3 >"${test_dir}/upgrade.log" 2>&1
exec 3>&-
(( SECONDS - timeout_started >= 29 )) || fail 'upgrade must wait for the configured timeout'
assert_eq $'migrations\nsuccess' "$(cat "${BACKUP_EVENTS}")"
assert_contains "$(cat "${test_dir}/upgrade.log")" 'Input timed out; using default: y'
printf 'PASS: unanswered backup confirmation waits 30 seconds and then completes the upgrade\n'

# Existing unattended installation behavior adopts the shown default immediately.
: >"${BACKUP_EVENTS}"
AUTO_INSTALL=1 backup_db </dev/null >"${test_dir}/backup.log"
assert_contains "$(cat "${test_dir}/backup.log")" 'default: y): y'

# JDMC's full-upgrade worker exports AUTO_INSTALL=1 and has no interactive
# stdin. Run the real upgrade_jdmc function, mocking only its host operations.
(
  . "${TEST_ROOT}/scripts/gists/jdmc.sh"
  export USE_XPACK=1 AUTO_INSTALL=1
  jdmc_action_result=0
  check_jdmc_runtime() { :; }
  check_jdmc_installed() { return 0; }
  run_jdmc_package_action() {
    printf 'jdmc-%s\n' "$1" >>"${BACKUP_EVENTS}"
    return "${jdmc_action_result}"
  }
  ensure_jdmc_ha_dependencies() { :; }
  printf 'mock archive\n' >"${UPGRADE_TEST_IMAGES}/jdmc:${VERSION}.zst"
  printf 'sha256:installed\n' >"${UPGRADE_TEST_IMAGES}/jdmc:${VERSION}.sha256"

  for selected_db_image in mariadb:10.6 postgres:16.15-bookworm; do
    select_database "${selected_db_image}"
    for installed_db_image in '' "${selected_db_image}"; do
      set_config CURRENT_VERSION v3.10.21
      : >"${BACKUP_EVENTS}"
      auto_started=${SECONDS}
      (main) </dev/null >"${test_dir}/jdmc-upgrade.log" 2>&1
      (( SECONDS - auto_started < 30 )) || fail 'JDMC unattended upgrades must not wait for backup confirmation'
      expected_events=''
      [[ -z "${installed_db_image}" ]] || expected_events=$'backup\n'
      expected_events+=$'migrations\njdmc-upgrade\nsuccess'
      assert_eq "${expected_events}" "$(cat "${BACKUP_EVENTS}")"
      assert_eq "${VERSION}" "$(get_config CURRENT_VERSION)"
      assert_contains "$(cat "${test_dir}/jdmc-upgrade.log")" 'default: y): y'
    done
  done

  jdmc_action_result=1
  set_config CURRENT_VERSION v3.10.21
  : >"${BACKUP_EVENTS}"
  if (main) </dev/null >"${test_dir}/jdmc-upgrade.log" 2>&1; then
    fail 'JDMC package upgrade failure must remain fatal after accepting backup failure'
  fi
  assert_eq $'backup\nmigrations\njdmc-upgrade' "$(cat "${BACKUP_EVENTS}")"
  assert_eq v3.10.21 "$(get_config CURRENT_VERSION)"
  assert_contains "$(cat "${test_dir}/jdmc-upgrade.log")" 'Failed to upgrade JDMC'

  jdmc_action_result=0
  rm "${UPGRADE_TEST_IMAGES}/jdmc:${VERSION}.zst"
  : >"${BACKUP_EVENTS}"
  if (main) </dev/null >"${test_dir}/jdmc-upgrade.log" 2>&1; then
    fail 'missing JDMC artifact must remain fatal even with an optional backup client'
  fi
  assert_eq '' "$(cat "${BACKUP_EVENTS}")"
  assert_contains "$(cat "${test_dir}/jdmc-upgrade.log")" 'Failed to load Docker images'
)
printf 'PASS: JDMC unattended upgrades reach the host upgrade without waiting and retain fatal artifact/package checks\n'

rm "${UPGRADE_TEST_IMAGES}/core:${VERSION}.zst"
: >"${BACKUP_EVENTS}"
if (main) <<<y >"${test_dir}/upgrade.log" 2>&1; then
  fail 'missing Core archive must stop the upgrade before backup confirmation or migrations'
fi
assert_eq '' "$(cat "${BACKUP_EVENTS}")"
assert_contains "$(cat "${test_dir}/upgrade.log")" 'Failed to load Docker images'
printf 'PASS: required application images remain fatal before backup confirmation\n'
