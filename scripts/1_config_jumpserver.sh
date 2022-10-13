#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

function set_secret_key() {
  echo_yellow "1. $(gettext 'Configure Private Key')"
  secret_key=$(get_config SECRET_KEY)
  if [[ -z "${secret_key}" ]]; then
    secret_key=$(random_str 48)
    set_config SECRET_KEY "${secret_key}"
    echo "SECRETE_KEY:     ${secret_key}"
  fi
  bootstrap_key=$(get_config BOOTSTRAP_TOKEN)
  if [[ -z "${bootstrap_key}" ]]; then
    bootstrap_key=$(random_str 24)
    set_config BOOTSTRAP_TOKEN "${bootstrap_key}"
    echo "BOOTSTRAP_TOKEN: ${bootstrap_key}"
  fi
  if command -v hostname >/dev/null; then
    SERVER_HOSTNAME=$(hostname)
    set_config SERVER_HOSTNAME "${SERVER_HOSTNAME}"
  fi
}

function set_volume_dir() {
  echo_yellow "\n2. $(gettext 'Configure Persistent Directory')"
  volume_dir=$(get_config VOLUME_DIR "/opt/jumpserver")
  confirm="n"
  read_from_input confirm "$(gettext 'Do you need custom persistent store, will use the default directory') ${volume_dir}?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    echo
    echo "$(gettext 'To modify the persistent directory such as logs video, you can select your largest disk and create a directory in it, such as') /data/jumpserver"
    echo "$(gettext 'Note: you can not change it after installation, otherwise the database may be lost')"
    echo
    df -h | grep -Ev "devfs|tmpfs|overlay|shm|snap|boot"
    echo
    read_from_input volume_dir "$(gettext 'Persistent storage directory')" "" "${volume_dir}"
    if [[ "${volume_dir}" == "y" ]]; then
      echo_failed
      echo
      set_volume_dir
    fi
  fi
  if [[ ! -d "${volume_dir}" ]]; then
    mkdir -p ${volume_dir}
    chmod 700 ${volume_dir}
  fi
  set_config VOLUME_DIR ${volume_dir}
}

function set_external_mysql() {
  mysql_host=$(get_config DB_HOST)
  read_from_input mysql_host "$(gettext 'Please enter MySQL server IP')" "" "${mysql_host}"
  if [[ "${mysql_host}" == "127.0.0.1" || "${mysql_host}" == "localhost" ]]; then
    mysql_host=$(hostname -I | cut -d ' ' -f1)
  fi
  mysql_port=$(get_config DB_PORT)
  read_from_input mysql_port "$(gettext 'Please enter MySQL server port')" "" "${mysql_port}"
  mysql_db=$(get_config DB_NAME)
  read_from_input mysql_db "$(gettext 'Please enter MySQL database name')" "" "${mysql_db}"
  mysql_user=$(get_config DB_USER)
  read_from_input mysql_user "$(gettext 'Please enter MySQL username')" "" "${mysql_user}"
  mysql_password=$(get_config DB_PASSWORD)
  read_from_input mysql_password "$(gettext 'Please enter MySQL password')" "" "${mysql_password}"

  set_config DB_HOST "${mysql_host}"
  set_config DB_PORT "${mysql_port}"
  set_config DB_USER "${mysql_user}"
  set_config DB_PASSWORD "${mysql_password}"
  set_config DB_NAME "${mysql_db}"
}

function set_internal_mysql() {
  mysql_password=$(get_config DB_PASSWORD)
  if [[ -z "${mysql_password}" ]]; then
    DB_PASSWORD=$(random_str 26)
    set_config DB_PASSWORD "${DB_PASSWORD}"
  fi
  mysql_db=$(get_config DB_NAME)
  if [[ -z "${mysql_db}" ]]; then
    set_config DB_NAME jumpserver
  fi
  set_config DB_HOST mysql
  set_config DB_PORT 3306
  set_config DB_USER root
}

function set_mysql() {
  echo_yellow "\n3. $(gettext 'Configure MySQL')"
  mysql_host=$(get_config DB_HOST)
  confirm="n"
  if [[ "${mysql_host}" != "mysql" ]]; then
    confirm="y"
  fi
  read_from_input confirm "$(gettext 'Do you want to use external MySQL')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    set_external_mysql
  else
    set_internal_mysql
  fi
}

function set_external_redis() {
  redis_host=$(get_config REDIS_HOST)
  read_from_input redis_host "$(gettext 'Please enter Redis server IP')" "" "${redis_host}"
  if [[ "${redis_host}" == "127.0.0.1" || "${redis_host}" == "localhost" ]]; then
    redis_host=$(hostname -I | cut -d ' ' -f1)
  fi
  redis_port=$(get_config REDIS_PORT)
  read_from_input redis_port "$(gettext 'Please enter Redis server port')" "" "${redis_port}"
  redis_password=$(get_config REDIS_PASSWORD)
  read_from_input redis_password "$(gettext 'Please enter Redis password')" "" "${redis_password}"

  set_config REDIS_HOST "${redis_host}"
  set_config REDIS_PORT "${redis_port}"
  set_config REDIS_PASSWORD "${redis_password}"
}

function set_internal_redis() {
  redis_password=$(get_config REDIS_PASSWORD)
  if [[ -z "${redis_password}" ]]; then
    REDIS_PASSWORD=$(random_str 26)
    set_config REDIS_PASSWORD "${REDIS_PASSWORD}"
  fi
  set_config REDIS_HOST redis
  set_config REDIS_PORT 6379
}

function set_redis() {
  echo_yellow "\n4. $(gettext 'Configure Redis')"
  redis_host=$(get_config REDIS_HOST)
  confirm="n"
  if [[ "${redis_host}" != "redis" ]]; then
    confirm="y"
  fi
  read_from_input confirm "$(gettext 'Do you want to use external Redis')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    set_external_redis
  else
    set_internal_redis
  fi
}

function set_service_port() {
  echo_yellow "\n5. $(gettext 'Configure External Port')"
  http_port=$(get_config HTTP_PORT)
  ssh_port=$(get_config SSH_PORT)
  rdp_port=$(get_config RDP_PORT)
  use_xpack=$(get_config_or_env USE_XPACK)
  confirm="n"
  read_from_input confirm "$(gettext 'Do you need to customize the JumpServer external port')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    read_from_input http_port "$(gettext 'JumpServer web port')" "" "${http_port}"
    set_config HTTP_PORT "${http_port}"
    read_from_input ssh_port "$(gettext 'JumpServer ssh port')" "" "${ssh_port}"
    set_config SSH_PORT "${ssh_port}"
    if [[ "${use_xpack}" == "1" ]]; then
      read_from_input rdp_port "$(gettext 'JumpServer rdp port')" "" "${rdp_port}"
      set_config RDP_PORT "${rdp_port}"
    fi
  fi
}

function init_db() {
  echo_yellow "\n6. $(gettext 'Init JumpServer Database')"
  if ! perform_db_migrations; then
    log_error "$(gettext 'Failed to change the table structure')!"
    exit 1
  fi
}

function main() {
  if set_secret_key; then
    echo_done
  fi
  if set_volume_dir; then
    echo_done
  fi
  if set_mysql; then
    echo_done
  fi
  if set_redis; then
    echo_done
  fi
  if set_service_port; then
    echo_done
  fi
  if init_db; then
    echo_done
  fi
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
