#!/usr/bin/env bash
#
export SHELLOPTS

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

cd "${PROJECT_DIR}" || exit 1

. "${PROJECT_DIR}/scripts/utils.sh"

action=${1-}
target=${2-}
args=("$@")
skip_jdmc=false

if [[ "${target}" == "--skip-jdmc" || "${target}" == "--skip-kotl" ]]; then
  case "${action}" in
  start|stop|restart|close|status|down)
    skip_jdmc=true
    target=""
    ;;
  esac
fi

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

function pre_check() {
  check_config_file || return 3
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
  echo "  start [--skip-jdmc]   $(gettext 'Start     JumpServer')"
  echo "  stop [--skip-jdmc]    $(gettext 'Stop      JumpServer')"
  echo "  restart [--skip-jdmc] $(gettext 'Restart   JumpServer')"
  echo "  status [--skip-jdmc]  $(gettext 'Check     JumpServer')"
  echo "  down              $(gettext 'Offline   JumpServer')"
  echo "  uninstall         $(gettext 'Uninstall JumpServer')"
  echo
  echo "More Commands: "
  echo "  load_image        $(gettext 'Loading docker image')"
  echo "  backup_db         $(gettext 'Backup database')"
  echo "  backup_no_audit   $(gettext 'Backup database without audit data')"
  echo "  backup_audit      $(gettext 'Backup audits tables')"
  echo "  restore_db [file]        $(gettext 'Data recovery through database backup file')"
  echo "  raw               $(gettext 'Execute the original docker compose command')"
  echo "  tail [service]    $(gettext 'View log')"
  echo
}

function service_to_docker_name() {
  service=$1
  if [[ "${service:0:3}" != "jms" ]]; then
    service=jms_${service}
  fi
  echo "${service}"
}

EXE=""

function should_manage_jdmc() {
  [[ "${skip_jdmc}" != "true" ]]
}

function is_jdmc_target() {
  [[ "${target}" == "jdmc" || "${target}" == "kotl" ]]
}

function start() {
  set_openbao || return 1
  configure_jdmc || return 1
  gen_safe_config >/dev/null
  EXE=$(get_docker_compose_cmd_line)
  ${EXE} up -d || return 1

  ensure_current_installer_link || return 1
  if should_manage_jdmc; then
    start_jdmc
  fi
}

function stop() {
  if is_jdmc_target; then
    stop_jdmc
  elif [[ "${target}" == "ignore_db" ]]; then
    if should_manage_jdmc; then
      stop_jdmc || return 1
    fi
    cmd=$(get_docker_compose_cmd_line "ignore_db")
    ${cmd} down -v
  elif [[ -n "${target}" ]]; then
    ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
  else
    if should_manage_jdmc; then
      stop_jdmc || return 1
    fi
    ${EXE} down -v
  fi
}

function close() {
  if [[ -n "${target}" ]]; then
    if is_jdmc_target; then
      stop_jdmc
      return
    fi
    ${EXE} stop "${target}"
    return
  fi
  if should_manage_jdmc; then
    stop_jdmc || return 1
  fi
  services=$(get_docker_compose_services ignore_db)
  for i in ${services}; do
    ${EXE} stop "${i}"
  done
}

function pull() {
   if [[ -n "${target}" ]]; then
    ${EXE} pull "${target}"
    return
  fi
  ${EXE} pull
}

function restart() {
  if is_jdmc_target; then
    restart_jdmc
    return
  fi
  stop || return 1
  echo -e "\n"

  if [[ -n "${target}" && "${target}" != "ignore_db" ]]; then
    ${EXE} up -d "${target}"
    return
  fi
  start
}

function clean() {
  rm -f scripts/docker/*
  rm -f scripts/images/*
}

function check_update() {
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
  EXE=$(get_video_worker_cmd_line)
  if [[ ! "${EXE}" ]]; then
    log_error "video-worker is only available in the enterprise edition"
    return 1
  fi
  case "${target}" in
    start) ${EXE} up -d ;;
    stop) ${EXE} down -v ;;
    restart)
      ${EXE} down -v && ${EXE} up -d
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

function main() {
  check_os || return 3

  if [[ "${action}" == "help" || "${action}" == "h" || "${action}" == "-h" || "${action}" == "--help" ]]; then
    echo ""
  elif [[ "${action}" == "install" || "${action}" == "config" || "${action}" == "reconfig" ]]; then
    echo ""
  else
    pre_check || return 3
    EXE=$(get_docker_compose_cmd_line)
  fi
  case "${action}" in
  install)
    bash "${SCRIPT_DIR}/4_install_jumpserver.sh"
    ;;
  upgrade)
    bash "${SCRIPT_DIR}/7_upgrade.sh" "$target"
    ;;
  check_update)
    check_update
    ;;
  config)
    bash "${SCRIPT_DIR}/config.sh" "$target"
    ;;
  reconfig)
    ${EXE} down -v
    bash "${SCRIPT_DIR}/1_config_jumpserver.sh"
    ;;
  start)
    start
    ;;
  restart)
    restart
    ;;
  stop)
    stop 
    ;;
  pull)
    pull
    ;;
  close)
    close
    ;;
  status)
    ${EXE} ps
    if should_manage_jdmc; then
      status_jdmc
    fi
    ;;
  down)
    if [[ -z "${target}" ]]; then
      if should_manage_jdmc; then
        stop_jdmc || exit 1
      fi
      ${EXE} down -v
    elif is_jdmc_target; then
      stop_jdmc
    else
      ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
    fi
    ;;
  uninstall)
    bash "${SCRIPT_DIR}/8_uninstall.sh"
    ;;
  migrate_db)
    if ! perform_db_migrations; then
      log_error "$(gettext 'Failed to change the table structure')!"
      exit 1
    fi
    ;;
  backup_db)
    bash "${SCRIPT_DIR}/5_db_backup.sh"
    ;;
  backup_no_audit)
    bash "${SCRIPT_DIR}/5_db_backup.sh" "no_audit"
    ;;
  backup_audit)
    bash "${SCRIPT_DIR}/5_db_backup.sh" "audit"
    ;;
  restore_db)
    bash "${SCRIPT_DIR}/6_db_restore.sh" "$target"
    ;;
  load_image)
    bash "${SCRIPT_DIR}/3_load_images.sh"
    ;;
  pull_images)
    pull_images
    ;;
  pull_mysql)
    docker pull registry.cn-beijing.aliyuncs.com/jumpservice/mysql:8.0
    docker tag registry.cn-beijing.aliyuncs.com/jumpservice/mysql:8.0 mysql:8.0
    ;;
  cmd)
    echo "${EXE}"
    ;;
  tail)
    if is_jdmc_target; then
      tail_jdmc
    elif [[ -z "${target}" ]]; then
      ${EXE} logs --tail 100 -f
    else
      docker_name=$(service_to_docker_name "${target}")
      docker logs -f "${docker_name}" --tail 100
    fi
    ;;
  show_services)
    get_docker_compose_services
    ;;
  init_db)
    perform_db_migrations
    ;;
  restart_db)
    db_redis_restart "${target}"
    ;;
  stop_db)
    db_redis_stop "${target}"
    ;;
  start_db)
    db_redis_start "${target}"
    ;;
  cmd_db)
    get_db_compose_cmd "${target}"
    ;;
  video-worker)
    video-worker
    ;;
  raw)
    ${EXE} "${args[@]:1}"
    ;;
  version)
    get_current_version
    ;;
  help)
    usage
    ;;
  --help)
    usage
    ;;
  -h)
    usage
    ;;
  *)
    echo "No such command: ${action}"
    usage
    return 2
    ;;
  esac
}

main "$@"
