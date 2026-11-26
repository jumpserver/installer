#!/usr/bin/env bash
#
export SHELLOPTS

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

cd "${PROJECT_DIR}" || exit 1

. "${PROJECT_DIR}/scripts/utils.sh"

function check_config_file() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "$(gettext 'Configuration file not found'): ${CONFIG_FILE}"
    echo "$(gettext 'If you are upgrading from v1.5.x, please copy the config.txt To') ${CONFIG_FILE}"
    return 3
  fi
  if [[ -f .env ]]; then
    if ! ls -l .env | grep "${CONFIG_FILE}" &>/dev/null; then
      echo ".env $(gettext 'There is a problem with the soft connection, Please update it again')"
      rm -f .env
    fi
  fi

  if [[ ! -f ".env" ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi

  if [[ ! -f "./compose/.env" ]]; then
    ln -s "${CONFIG_FILE}" ./compose/.env
  fi
  gen_safe_config >/dev/null
}

function usage() {
  echo "$(gettext 'JumpServer Deployment Management Script')"
  echo
  echo "Usage: "
  echo "  ./jmsctl.sh [COMMAND] [ARGS...]"
  echo "  ./jmsctl.sh --help"
  echo
  echo "Installation Commands: "
  echo "  install           $(gettext 'Install JumpServer')"
  echo "  upgrade           $(gettext 'Upgrade JumpServer')"
  echo
  echo "Management Commands: "
  echo "  config            $(gettext 'Configuration  Tools')"
  echo "  start [service|--skip-jdmc]   $(gettext 'Start     JumpServer')"
  echo "  stop [--skip-jdmc]    $(gettext 'Stop      JumpServer')"
  echo "  restart [service|--skip-jdmc] $(gettext 'Restart   JumpServer')"
  echo "  status [--skip-jdmc]  $(gettext 'Check     JumpServer')"
  echo "  down              $(gettext 'Offline   JumpServer')"
  echo "  uninstall         $(gettext 'Uninstall JumpServer')"
  echo
  echo "More Commands: "
  echo "  prepare [service ...]  Prepare service files and permissions without starting services"
  echo "  prepare --containers <container ...>  Prepare stopped containers using their installed images"
  echo "  load_image        $(gettext 'Loading docker image')"
  echo "  backup_db         $(gettext 'Backup database')"
  echo "  backup_no_audit   $(gettext 'Backup database without audit data')"
  echo "  backup_audit      $(gettext 'Backup audits tables')"
  echo "  restore_db [file]        $(gettext 'Data recovery through database backup file')"
  echo "  raw               $(gettext 'Execute the original docker compose command')"
  echo "  tail [service]    $(gettext 'View log')"
  echo
}

# The executor must be ready before any services that use it are started.
function up_application_stack() {
  local compose_cmd=$1 operation=$2 enabled service
  local -a up_args=("${@:3}") remaining=()
  if [[ "$(get_config_or_env ANSIBLE_EXECUTOR_ENABLED)" == 0 ]]; then
    ${compose_cmd} "${up_args[@]}"
    return
  fi
  ${compose_cmd} "${up_args[@]}" --wait --wait-timeout 60 ansible-executor || return 1
  if [[ "$operation" == start ]]; then
    ${compose_cmd} "${up_args[@]}"
    return
  fi

  # The executor has already been rebuilt. Recreate each remaining service once.
  enabled=$(${compose_cmd} config --services) || return 1
  [[ -n "$enabled" ]] || return 1
  while IFS= read -r service; do
    [[ "$service" == ansible-executor ]] || remaining+=("$service")
  done <<<"$enabled"
  if (( ${#remaining[@]} )); then
    ${compose_cmd} "${up_args[@]}" --no-deps "${remaining[@]}"
  fi
}

function start_applications() {
  local operation=$1 service=${2:-} compose_cmd
  local -a flags=(up -d)
  [[ "$operation" != restart ]] || flags+=(--force-recreate)
  if [[ -z "$service" ]]; then
    postgresql_upgrade_start_guard || return 1
    set_openbao || return 1
    gen_safe_config >/dev/null || return 1
  fi
  compose_cmd=$(get_docker_compose_cmd_line) || return 1
  if [[ -n "$service" ]]; then
    [[ "$service" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || return 2
    prepare_services_for_start "$service" || return 1
    ${compose_cmd} "${flags[@]}" "$service" || return 1
  else
    stop_disabled_video_worker || return 1
    prepare_services_for_start || return 1
    up_application_stack "$compose_cmd" "$operation" "${flags[@]}" || return 1
  fi
  remove_stopped_openbao_init_container
}

function start_or_restart_jumpserver() {
  if [[ "$skip_jdmc" == true || ( -n "$target" && "$target" != ignore_db ) ]]; then
    start_applications "$action" "$target"
    return
  fi
  if [[ "$action" == restart ]]; then
    run_compose_command stop || return 1
  fi

  local current=/opt/current/installer switching_release=false
  if is_jdmc_enabled; then
    if [[ ( -e "$current" || -L "$current" ) && ! "$PROJECT_DIR" -ef "$current" ]]; then
      # Keep the working JDMC online until the new release has started.
      if ! configure_container_jdmc; then
        export JDMC_CALLBACK_UNAVAILABLE=1
        warn_jdmc_unavailable "JDMC callback setup failed. After repair, run ./jmsctl.sh start jdmc, ./jmsctl.sh start core and ./jmsctl.sh start celery"
      fi
      switching_release=true
    else
      container_jdmc_action start || warn_jdmc_unavailable "JDMC failed to start. Retry ./jmsctl.sh start jdmc"
    fi
  fi
  start_applications start || return 1
  ensure_current_installer_link || return 1
  if [[ "$switching_release" == true ]]; then
    container_jdmc_action start || warn_jdmc_unavailable "JDMC failed to start. Retry ./jmsctl.sh start jdmc"
  fi
}

function run_compose_command() {
  local command=$1 compose_cmd services service container
  shift
  compose_cmd=$(get_docker_compose_cmd_line) || return 1
  case "$command" in
    stop|down)
      if [[ "$command" == stop && "$target" == ignore_db ]]; then
        compose_cmd=$(get_docker_compose_cmd_line ignore_db) || return 1
        ${compose_cmd} down -v
      elif [[ -n "$target" ]]; then
        ${compose_cmd} stop "$target" && ${compose_cmd} rm -f "$target"
      else
        ${compose_cmd} down -v
      fi
      ;;
    close)
      if [[ -n "$target" ]]; then
        ${compose_cmd} stop "$target"
      else
        services=$(get_docker_compose_services ignore_db)
        for service in ${services}; do
          ${compose_cmd} stop "$service"
        done
      fi
      ;;
    status)
      ${compose_cmd} ps
      if [[ "$skip_jdmc" == false ]] && is_jdmc_enabled; then
        container_jdmc_action ps
      fi
      ;;
    tail)
      if [[ -n "$target" ]]; then
        container=$target
        [[ "$container" == jms* ]] || container=jms_$target
        docker logs -f "$container" --tail 100
      else
        ${compose_cmd} logs --tail 100 -f
      fi
      ;;
    reconfig)
      ${compose_cmd} down -v || return 1
      bash "${SCRIPT_DIR}/1_config_jumpserver.sh"
      ;;
    pull)
      if [[ -n "$target" ]]; then
        ${compose_cmd} pull "$target"
      else
        ${compose_cmd} pull
      fi
      ;;
    raw)  ${compose_cmd} "$@" ;;
    cmd)  echo "$compose_cmd" ;;
  esac
}

function check_update() {
  local current_version latest_version
  current_version=$(get_current_version)
  latest_version=$(get_latest_version)
  if [[ "${current_version}" == "${latest_version}" ]]; then
    echo_green "$(gettext 'The current version is up to date'): ${latest_version}"
    echo
    return
  fi
  if [[ -n "${latest_version}" ]] && [[ ${latest_version} =~ v.* ]]; then
    echo -e "\033[32m$(gettext 'The latest version is'): ${latest_version}\033[0m"
  else
    exit 1
  fi
}

function video-worker() {
  local EXE
  EXE=$(get_video_worker_cmd_line)
  if [[ ! "${EXE}" ]]; then
    log_error "video-worker is only available in the enterprise edition"
    return 1
  fi
  if [[ "${target}" == start || "${target}" == restart ]]; then
    postgresql_upgrade_start_guard || return 1
  fi
  case "${target}" in
    start)
      if ! video_worker_can_start; then
        log_error "video-worker is disabled by VIDEO_WORKER_ENABLED=0"
        return 1
      fi
      prepare_services_for_start video-worker && ${EXE} up -d
      ;;
    stop) ${EXE} down -v ;;
    restart)
      if ! video_worker_can_start; then
        log_error "video-worker is disabled by VIDEO_WORKER_ENABLED=0"
        return 1
      fi
      ${EXE} down -v && prepare_services_for_start video-worker && ${EXE} up -d
      ;;
    status) ${EXE} ps ;;
    *)
      log_error "Usage: ./jmsctl.sh video-worker {start|stop|restart|status}"
      return 2
      ;;
  esac
}

function check_os() {
  if [[ -n "$UNCHECK_DEPENDENCIES" ]]; then
    return 0
  fi
  if [[ "${OS}" == 'Darwin' ]]; then
    echo
    echo "$(gettext 'Unsupported Operating System Error')"
    echo "$(gettext 'macOS installer please see'): https://github.com/jumpserver/Dockerfile"
    return 1
  fi
  if [[ "${OS}" =~ MINGW.* ]]; then
    echo
    echo "$(gettext 'Unsupported Operating System Error')"
    echo "$(gettext 'Windows installer please see'): https://github.com/jumpserver/Dockerfile"
    return 1
  fi
  return 0
}

function manage_jdmc() {
  if ! is_jdmc_enabled; then
    log_error "JDMC is only available in the enterprise edition"
    return 1
  fi
  container_jdmc_action "$1"
}

function check_ha_handoff() {
  # JDMC_CONTAINER_HANDOFF_V1. A transfer can leave application writers stopped.
  can_manage_existing_jdmc || return 0
  jdmc_path_exists "$(get_current_jdmc_data_dir)/management/ha/handoff.json" || return 0
  case "$action" in
    status|tail|help|h|-h|--help) return 0 ;;
    start)
      if [[ -z "$target" && "$skip_jdmc" == false ]]; then
        container_jdmc_action start || return 1
      fi
      log_error "JDMC HA controls application startup on this node. Open HA management for its handoff state."
      ;;
    *) log_error "JDMC HA controls service changes during an independent-data handoff." ;;
  esac
  return 1
}

function main() {
  local action=${1-} target=${2-} skip_jdmc=false
  check_os || return 3
  case "$action" in
    start|stop|restart|close|status|down)
      if [[ "$target" == --skip-jdmc ]]; then
        skip_jdmc=true
        target=""
      fi
      ;;
  esac
  case "$action" in
    help|h|-h|--help|version|status|tail|cmd|cmd_db|show_services|check_update) ;;
    *) check_jdmc_deployment || return 1 ;;
  esac
  # The recovery UI can operate before the business Compose configuration is ready.
  if [[ "$target" == jdmc ]]; then
    case "$action" in
      start|restart)   manage_jdmc "$action"; return ;;
      stop|close|down) manage_jdmc stop; return ;;
      status)          manage_jdmc ps; return ;;
      tail)            manage_jdmc logs; return ;;
    esac
  fi
  check_ha_handoff || return 1

  case "$action" in
    help|h|-h|--help) usage; return ;;
    install)   bash "${SCRIPT_DIR}/4_install_jumpserver.sh"; return ;;
    uninstall) bash "${SCRIPT_DIR}/8_uninstall.sh"; return ;;
    config)    bash "${SCRIPT_DIR}/config.sh" "$target"; return ;;
    prepare)
      # Standby preparation needs only the existing configuration file.
      if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: ${CONFIG_FILE}"
        return 3
      fi
      prepare_services_for_start "${@:2}"
      return
      ;;
  esac
  check_config_file || return 3

  case "$action" in
    start|restart) start_or_restart_jumpserver ;;
    stop|down|close|pull|status|tail|raw|cmd|reconfig) run_compose_command "$@" ;;
    video-worker) video-worker ;;

    backup_db|backup_no_audit|backup_audit|restore_db)
      postgresql_upgrade_start_guard || return 1
      case "$action" in
        backup_db)       bash "${SCRIPT_DIR}/5_db_backup.sh" ;;
        backup_no_audit) bash "${SCRIPT_DIR}/5_db_backup.sh" no_audit ;;
        backup_audit)    bash "${SCRIPT_DIR}/5_db_backup.sh" audit ;;
        restore_db)      bash "${SCRIPT_DIR}/6_db_restore.sh" "$target" ;;
      esac
      ;;
    migrate_db)
      if ! perform_db_migrations; then
        log_error "$(gettext 'Failed to change the table structure')!"
        return 1
      fi
      ;;
    init_db)    perform_db_migrations ;;
    restart_db) db_redis_restart "$target" ;;
    stop_db)    db_redis_stop "$target" ;;
    start_db)   db_redis_start "$target" ;;
    cmd_db)     get_db_compose_cmd "$target" ;;

    upgrade)      bash "${SCRIPT_DIR}/7_upgrade.sh" "$target" ;;
    check_update) check_update ;;
    version)      get_current_version ;;
    show_services) get_docker_compose_services ;;
    load_image)   bash "${SCRIPT_DIR}/3_load_images.sh" ;;
    pull_images)  pull_images ;;
    pull_mysql)
      docker pull registry.cn-beijing.aliyuncs.com/jumpservice/mysql:8.0
      docker tag registry.cn-beijing.aliyuncs.com/jumpservice/mysql:8.0 mysql:8.0
      ;;
    *)
      echo "No such command: ${action}"
      usage
      return 2
      ;;
  esac
}

main "$@"
