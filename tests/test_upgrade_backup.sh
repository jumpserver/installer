#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/upgrade-backup"
mkdir -p "${test_dir}/volume" "${test_dir}/scripts"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"
. "${TEST_ROOT}/scripts/7_upgrade.sh" ''

set_config VOLUME_DIR "${test_dir}/volume"
set_config DB_ENGINE mysql
set_config DB_HOST db.example.test
set_config DB_IMAGE mariadb:10.6
set_config HA_MODE 0
unset SKIP_BACKUP_DB
SCRIPT_DIR="${test_dir}/scripts"
export BACKUP_EVENTS="${test_dir}/events" BACKUP_RESULT=0
cat >"${SCRIPT_DIR}/5_db_backup.sh" <<'EOF'
#!/usr/bin/env bash
printf 'backup\n' >>"${BACKUP_EVENTS}"
exit "${BACKUP_RESULT}"
EOF

installed_db_image=''
docker() {
  case "$1 ${2:-}" in
    'image inspect')
      case "${*: -1}" in
        redis:7.4.10-bookworm|"jumpserver/core:${VERSION}") printf 'sha256:installed\n' ;;
        *) [[ "${*: -1}" == "${installed_db_image}" ]] ;;
      esac
      ;;
    'tag '*) installed_db_image=$3 ;;
    *) fail "Unexpected Docker command: $*" ;;
  esac
}
gettext() { printf '%s\n' "$1"; }
log_warn() { printf 'WARNING: %s\n' "$*"; }
read_from_input() { fail 'external MySQL backup failure must not prompt'; }

for selected_db_image in mariadb:10.6 mysql:8.0; do
  set_config DB_IMAGE "${selected_db_image}"
  installed_db_image=''
  : >"${BACKUP_EVENTS}"
  backup_db >"${test_dir}/backup.log"
  assert_contains "$(cat "${test_dir}/backup.log")" "WARNING: External MySQL backup image ${selected_db_image} is unavailable"
  assert_contains "$(cat "${test_dir}/backup.log")" 'No installer database backup was created'
  assert_eq '' "$(cat "${BACKUP_EVENTS}")" 'missing clients must not run backup or trigger an implicit pull'

  for installed_db_image in "${selected_db_image}" "jumpserver/${selected_db_image}"; do
    BACKUP_RESULT=0
    : >"${BACKUP_EVENTS}"
    backup_db >"${test_dir}/backup.log"
    assert_eq backup "$(cat "${BACKUP_EVENTS}")" 'available clients must still attempt a backup'
    assert_eq '' "$(cat "${test_dir}/backup.log")" 'successful backups must not warn'
    assert_eq "${selected_db_image}" "${installed_db_image}" 'legacy client tags must be reusable'
  done

  BACKUP_RESULT=1
  : >"${BACKUP_EVENTS}"
  backup_db >"${test_dir}/backup.log"
  assert_eq backup "$(cat "${BACKUP_EVENTS}")"
  assert_contains "$(cat "${test_dir}/backup.log")" 'WARNING: Failed to back up external MySQL; continuing upgrade'
done
printf 'PASS: missing clients and failed external MySQL backups warn without prompting or aborting\n'

remove_config DB_ENGINE
backup_db >"${test_dir}/backup.log"
assert_contains "$(cat "${test_dir}/backup.log")" 'WARNING: Failed to back up external MySQL'
export SKIP_BACKUP_DB=1
: >"${BACKUP_EVENTS}"
backup_db >"${test_dir}/backup.log"
assert_eq '' "$(cat "${BACKUP_EVENTS}")" 'explicitly skipped backups must not be attempted'
assert_contains "$(cat "${test_dir}/backup.log")" 'Skip database backup'
unset SKIP_BACKUP_DB
printf 'PASS: legacy MySQL configurations and explicit backup skipping remain supported\n'

# Built-in databases and HA keep the existing confirmation on backup failure.
read_from_input() { printf 'confirm\n' >>"${BACKUP_EVENTS}"; }
set_config DB_ENGINE mysql
for deployment in internal ha; do
  set_config DB_HOST mysql
  set_config HA_MODE 0
  if [[ "${deployment}" == ha ]]; then
    set_config DB_HOST db.example.test
    set_config HA_MODE 1
  fi
  : >"${BACKUP_EVENTS}"
  if (backup_db) >"${test_dir}/backup.log"; then
    fail "${deployment} backup failure must still stop when continuing is not confirmed"
  fi
  assert_eq $'backup\nconfirm' "$(cat "${BACKUP_EVENTS}")"
done
printf 'PASS: built-in and HA database backup failures retain their existing confirmation\n'

# Exercise the upgrade entry point and real image loader together. Host changes
# and migrations are recorded instead of touching Docker or a real database.
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
set_config DB_IMAGE mariadb:10.6
set_config HA_MODE 0
set_config CURRENT_VERSION v3.10.21
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

for installed_db_image in '' mariadb:10.6; do
  : >"${BACKUP_EVENTS}"
  (main) >"${test_dir}/upgrade.log" 2>&1
  if [[ -z "${installed_db_image}" ]]; then
    assert_eq $'confirm\nmigrations\nsuccess' "$(cat "${BACKUP_EVENTS}")"
    assert_contains "$(cat "${test_dir}/upgrade.log")" 'External MySQL backup image mariadb:10.6 could not be prepared; upgrade will continue'
    assert_contains "$(cat "${test_dir}/upgrade.log")" 'No installer database backup was created'
  else
    assert_eq $'confirm\nbackup\nmigrations\nsuccess' "$(cat "${BACKUP_EVENTS}")"
    assert_contains "$(cat "${test_dir}/upgrade.log")" 'Failed to back up external MySQL; continuing upgrade'
  fi
  assert_eq "${VERSION}" "$(get_config CURRENT_VERSION)" 'upgrade must finish after optional backup failures'
done
printf 'PASS: actual upgrade flow reaches migrations and completion after missing clients or failed backups\n'

rm "${UPGRADE_TEST_IMAGES}/core:${VERSION}.zst"
: >"${BACKUP_EVENTS}"
if (main) >"${test_dir}/upgrade.log" 2>&1; then
  fail 'missing Core archive must stop the upgrade before migrations'
fi
assert_eq confirm "$(cat "${BACKUP_EVENTS}")"
assert_contains "$(cat "${test_dir}/upgrade.log")" 'Failed to load Docker images'
printf 'PASS: actual upgrade flow still stops before migrations when an application image is missing\n'
