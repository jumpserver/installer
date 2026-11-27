#!/usr/bin/env bash

JDMC_SERVICE_NAME=${JDMC_SERVICE_NAME:-jdmc.service}
JDMC_INSTALL_DIR=${JDMC_INSTALL_DIR:-/opt/jdmc}
JDMC_LEGACY_SERVICE_NAME=${KOTL_SERVICE_NAME:-kotl.service}
JDMC_LEGACY_INSTALL_DIR=${KOTL_INSTALL_DIR:-/opt/kotl}
JDMC_SYSTEMD_DIRS=${JDMC_SYSTEMD_DIRS:-/etc/systemd/system:/run/systemd/system:/usr/local/lib/systemd/system:/usr/lib/systemd/system:/lib/systemd/system}

function is_enterprise_edition() {
  [[ "${VERSION:-}" != *-ce && "$(get_config_or_env USE_XPACK 0)" == "1" ]]
}

function is_jdmc_enabled() {
  is_enterprise_edition
}

function warn_jdmc_unavailable() {
  local message="$1. Continuing with JumpServer."
  log_warn "$message"
  if [[ -n ${JDMC_UPGRADE_LOG_DIR:-} ]]; then
    printf '%s\n' "$message" >> "$JDMC_UPGRADE_LOG_DIR/jdmc-upgrade-warning" ||
      log_warn "Could not save the JDMC warning to the upgrade directory."
  fi
}

function can_manage_existing_jdmc() {
  # A lost config.txt must not bypass HA protection or strand an EE uninstall.
  is_jdmc_enabled || [[ "${VERSION:-}" == *-ee && ! -f "${CONFIG_FILE}" ]]
}

function get_container_jdmc_image_override() {
  local image
  image=$(get_config_or_env JDMC_IMAGE)
  if [[ -n "$image" ]] && is_jdmc_enabled; then
    printf '%s\n' "$image"
  fi
}

function get_jdmc_image() {
  local image
  image=$(get_container_jdmc_image_override)
  printf '%s\n' "${image:-$(get_image_namespace)/jdmc:${VERSION}}"
}

function cleanup_jdmc_legacy_switches() {
  remove_config KOTL_ENABLED
  remove_config JDMC_HOST_ENABLED
  remove_config JDMC_ENABLED
  gen_safe_config >/dev/null
}

function jdmc_unit_exists() {
  local service_name=$1

  [[ -f "/etc/systemd/system/${service_name}" ||
    -f "/lib/systemd/system/${service_name}" ||
    -f "/usr/lib/systemd/system/${service_name}" ]]
}

function jdmc_path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

function get_jdmc_storage_root() {
  local volume_dir

  volume_dir=$(get_config_or_env VOLUME_DIR /data/jumpserver)
  volume_dir="${volume_dir%/}"
  [[ -n "${volume_dir}" ]] || volume_dir=/data/jumpserver
  dirname "${volume_dir}"
}

function get_current_jdmc_data_dir() {
  echo "$(get_jdmc_storage_root)/jdmc"
}

function get_legacy_kotl_data_dir() {
  echo "$(get_jdmc_storage_root)/kotl"
}

# Container HA stores its handoff in management/ha. These markers belong to
# the host services and must be retired with the installer that created them.
function check_jdmc_deployment() {
  [[ "${VERSION:-}" == *-ee || "${1:-}" == *-ee ]] || is_jdmc_enabled || return 0
  local root marker
  if [[ "${HA_MODE:-0}" == 1 || "$(get_config HA_MODE)" == 1 ]]; then
    log_error "Legacy host HA (HA_MODE=1) requires retirement with the original installer and a fresh installation."
    return 1
  fi
  root=$(get_jdmc_storage_root) || return 1
  for marker in "$root"/{jdmc,kotl}/ha/{installed,rollback-terminal.json,standalone-prepare,standalone,retired-safe}; do
    if jdmc_path_exists "$marker"; then
      log_error "Legacy host HA detected at $marker. Retire it with the original installer, then reinstall."
      return 1
    fi
  done
  return 0
}

function jdmc_managed_host_file() {
  [[ -f "$1" && ! -L "$1" && $(stat -c %u -- "$1") == 0 &&
     $(head -n1 -- "$1") == '# Managed by JumpServer JDMC' ]]
}

function jdmc_uninstall_ready() {
  local active
  if [[ -d /etc/docker/.jdmc-undo.pending || -d /etc/docker/.jdmc-undo.claimed ]]; then
    log_error "A previous JDMC release left a Docker recovery record in /etc/docker. Check the configuration and finish recovery on the host before uninstalling."
    return 1
  fi
  if [[ -d /run/systemd/system ]]; then
    active=$(systemctl list-units --plain --no-legend --state=active,activating,reloading,deactivating \
             'jumpserver-jdmc-maintenance[-@]*.service') || return 1
    [[ -z "$active" ]] || { log_error "A JDMC package maintenance task is running"; return 1; }
  fi
}

function remove_container_jdmc_integration() {
  local unit=/etc/systemd/system/jumpserver-jdmc-maintenance@.service
  local profile=/etc/apparmor.d/jumpserver-jdmc rule=/etc/tmpfiles.d/zz-jumpserver-jdmc.conf
  jdmc_uninstall_ready || return 1
  if jdmc_managed_host_file "$unit"; then
    rm -- "$unit" || return 1
    if [[ -d /run/systemd/system ]]; then systemctl daemon-reload || return 1; fi
  fi
  if jdmc_managed_host_file "$profile"; then
    local profiles=/sys/kernel/security/apparmor/profiles
    if [[ -r /sys/module/apparmor/parameters/enabled && $(< /sys/module/apparmor/parameters/enabled) == Y ]]; then
      [[ -r "$profiles" ]] || { log_error "Cannot inspect loaded AppArmor profiles"; return 1; }
      if grep -Eq '^jumpserver-jdmc \(' "$profiles"; then apparmor_parser -R "$profile" || return 1; fi
    fi
    rm -- "$profile" || return 1
  fi
  if jdmc_managed_host_file "$rule"; then rm -- "$rule" || return 1; fi
}

function prepare_jdmc_uninstall() {
  local node existing=''
  node=$(jdmc_installer_dir) || return 1
  # A first failed start can leave only releases. A VOLUME_DIR change can leave
  # only the container, whose ownership the down action checks before removal.
  if [[ ! -d "$node/releases" ]] && command -v docker >/dev/null; then
    existing=$(docker ps -aq --filter label=com.docker.compose.project=jdmc --filter label=com.docker.compose.service=jdmc) || return 1
  fi
  if [[ -d "$node/releases" || -n "$existing" ]]; then
    jdmc_uninstall_ready || return 1
    container_jdmc_action down || return 1
  fi
}

function remove_jdmc_main_service_unit() {
  local service_name=$1 install_dir=$2
  local systemd_dir candidate target_name
  local failed=0
  local changed=0
  local present=0
  local unit_file_present=0
  local -a systemd_dirs

  IFS=: read -r -a systemd_dirs <<<"${JDMC_SYSTEMD_DIRS}"
  for systemd_dir in "${systemd_dirs[@]}"; do
    if [[ -f "${systemd_dir}/${service_name}" ||
      -e "${systemd_dir}/multi-user.target.wants/${service_name}" ||
      -L "${systemd_dir}/multi-user.target.wants/${service_name}" ]]; then
      present=1
    fi
    [[ -f "${systemd_dir}/${service_name}" ]] && unit_file_present=1
  done
  [[ "${present}" == "1" ]] || return 0

  if [[ "${unit_file_present}" == "1" ]] && command -v systemctl &>/dev/null; then
    systemctl disable --now "${service_name}" &>/dev/null || systemctl stop "${service_name}" &>/dev/null || failed=1
  fi
  for systemd_dir in "${systemd_dirs[@]}"; do
    for target_name in "" multi-user.target.wants; do
      if [[ -n "${target_name}" ]]; then
        candidate="${systemd_dir}/${target_name}/${service_name}"
      else
        candidate="${systemd_dir}/${service_name}"
      fi
      if [[ -e "${candidate}" || -L "${candidate}" ]]; then
        if [[ -f "${candidate}" ]] && ! grep -Fq "${install_dir}" "${candidate}" 2>/dev/null; then
          continue
        fi
        echo -e "$(gettext 'Cleaning up') ${candidate}"
        if rm -f "${candidate}"; then
          changed=1
        else
          failed=1
        fi
      fi
    done
  done
  if [[ "${changed}" == "1" ]] && command -v systemctl &>/dev/null; then
    systemctl daemon-reload || failed=1
  fi
  return "${failed}"
}

function cleanup_jdmc_host_integration() {
  local failed=0

  remove_jdmc_main_service_unit "${JDMC_SERVICE_NAME}" "${JDMC_INSTALL_DIR}" || failed=1
  remove_jdmc_main_service_unit "${JDMC_LEGACY_SERVICE_NAME}" "${JDMC_LEGACY_INSTALL_DIR}" || failed=1
  return "${failed}"
}

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jdmc-container.sh"
