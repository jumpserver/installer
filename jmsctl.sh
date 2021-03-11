#!/bin/bash

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=scripts/utils.sh
. "${PROJECT_DIR}/scripts/utils.sh"

action=${1-}
target=${2-}
args=("$@")

function check_config_file() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "$(gettext 'Configuration file not found'): ${CONFIG_FILE}"
    echo "$(gettext 'If you are upgrading from v1.5.x, please copy the config.txt To') ${CONFIG_FILE}"
    return 3
  fi
  if [[ -f .env ]]; then
    ls -l .env | grep "${CONFIG_FILE}" &>/dev/null
    code="$?"
    if [[ "$code" != "0" ]]; then
      echo ".env $(gettext 'There is a problem with the soft connection, Please update it again')"
      rm -f .env
    fi
  fi

  if [[ ! -f .env ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi
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
  echo "  upgrade [version] $(gettext 'Upgrade JumpServer')"
  echo "  check_update      $(gettext 'Check for updates JumpServer')"
  echo "  reconfig          $(gettext 'Reconfiguration JumpServer')"
  echo
  echo "Management Commands: "
  echo "  start             $(gettext 'Start   JumpServer')"
  echo "  stop              $(gettext 'Stop    JumpServer')"
  echo "  close             $(gettext 'Close   JumpServer')"
  echo "  restart           $(gettext 'Restart JumpServer')"
  echo "  status            $(gettext 'Check   JumpServer')"
  echo "  down              $(gettext 'Offline JumpServer')"
  echo "  uninstall         $(gettext 'Uninstall JumpServer')"
  echo
  echo "More Commands: "
  echo "  load_image        $(gettext 'Loading docker image')"
  echo "  python            $(gettext 'Run python manage.py shell')"
  echo "  backup_db         $(gettext 'Backup database')"
  echo "  restore_db [file] $(gettext 'Data recovery through database backup file')"
  echo "  raw               $(gettext 'Execute the original docker-compose command')"
  echo "  tail [service]    $(gettext 'View log')"

}

function service_to_docker_name() {
  service=$1
  if [[ "${service:0:3}" != "jms" ]]; then
    service=jms_${service}
  fi
  echo "${service}"
}

EXE=""

function start() {
  check_ipv6_iptables_if_need
  ${EXE} up -d
}

function stop() {
  if [[ -n "${target}" ]]; then
    ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
    return
  fi
  services=$(get_docker_compose_services ignore_db)
  for i in ${services}; do
    ${EXE} stop "${i}"
  done
  for i in ${services}; do
    ${EXE} rm -f "${i}" >/dev/null
  done
  docker volume rm jms_share-volume &>/dev/null
}

function close() {
  if [[ -n "${target}" ]]; then
    ${EXE} stop "${target}"
    return
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
  stop
  echo -e "\n"
  start
}

function check_update() {
  current_version="${VERSION}"
  latest_version=$(get_latest_version)
  if [[ "${current_version}" == "${latest_version}" ]]; then
    echo "$(gettext 'The current version is up to date')"
    return
  fi
  echo "$(gettext 'The latest version is'): ${latest_version}"
  echo "$(gettext 'The current version is'): ${current_version}"
  echo
  bash "${SCRIPT_DIR}/7_upgrade.sh" "${latest_version}"
}

function main() {
  if [[ "${action}" == "help" || "${action}" == "h" || "${action}" == "-h" || "${action}" == "--help" ]]; then
    echo ""
  elif [[ "${action}" == "install" || "${action}" == "reconfig" ]]; then
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
  reconfig)
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
    ;;
  down)
    if [[ -z "${target}" ]]; then
      ${EXE} down -v
    else
      ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
    fi
    ;;
  uninstall)
    bash "${SCRIPT_DIR}/8_uninstall.sh"
    ;;
  backup_db)
    bash "${SCRIPT_DIR}/5_db_backup.sh"
    ;;
  restore_db)
    bash "${SCRIPT_DIR}/6_db_restore.sh" "$target"
    ;;
  load_image)
    bash "${SCRIPT_DIR}/3_load_images.sh"
    ;;
  cmd)
    echo "${EXE}"
    ;;
  tail)
    if [[ -z "${target}" ]]; then
      ${EXE} logs --tail 100 -f
    else
      docker_name=$(service_to_docker_name "${target}")
      docker logs -f "${docker_name}" --tail 100
    fi
    ;;
  python)
    docker exec -it jms_core python /opt/jumpserver/apps/manage.py shell
    ;;
  db)
    docker exec -it jms_core python /opt/jumpserver/apps/manage.py dbshell
    ;;
  exec)
    docker_name=$(service_to_docker_name "${target}")
    docker exec -it "${docker_name}" sh
    ;;
  show_services)
    get_docker_compose_services
    ;;
  raw)
    ${EXE} "${args[@]:1}"
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
    ;;
  esac
}

main "$@"
