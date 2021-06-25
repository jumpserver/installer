#!/bin/bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR=$(dirname ${BASE_DIR})

# shellcheck source=./util.sh
. "${BASE_DIR}/utils.sh"

function set_network() {
  # IPv6 支持
  echo_yellow "1. $(gettext 'Configure Network')"
  use_ipv6=$(get_config USE_IPV6)
  confirm="n"
  if [[ "${use_ipv6}" == "1" ]]; then
    confirm="y"
  fi
  read_from_input confirm "$(gettext 'Do you want to support IPv6')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    set_config USE_IPV6 1
  fi
  echo_done

  cd "${cwd}" || exit
}

function set_secret_key() {
  echo_yellow "\n2. $(gettext 'Configure Private Key')"
  # 生成随机的 SECRET_KEY 和 BOOTSTRAP_KEY
  secret_key=$(get_config SECRET_KEY)
  if [[ -z "${secret_key}" ]]; then
    secret_key=$(random_str 48)
    set_config SECRET_KEY "${secret_key}"
    echo "SECRETE_KEY:     ${secret_key}"
  fi

  bootstrap_key=$(get_config BOOTSTRAP_TOKEN)
  if [[ -z "${bootstrap_key}" ]]; then
    bootstrap_key=$(random_str 16)
    set_config BOOTSTRAP_TOKEN "${bootstrap_key}"
    echo "BOOTSTRAP_TOKEN: ${bootstrap_key}"
  fi
  echo_done
}

function set_volume_dir() {
  echo_yellow "\n3. $(gettext 'Configure Persistent Directory')"
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -z "${volume_dir}" ]]; then
    volume_dir="/opt/jumpserver"
  fi
  confirm="n"
  read_from_input confirm "$(gettext 'Do you need custom persistent store, will use the default directory') ${volume_dir}?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    echo
    echo "$(gettext 'To modify the persistent directory such as logs video, you can select your largest disk and create a directory in it, such as') /opt/jumpserver"
    echo "$(gettext 'Note: you can not change it after installation, otherwise the database may be lost')"
    echo
    df -h | egrep -v "map|devfs|tmpfs|overlay|shm"
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
  fi
  set_config VOLUME_DIR ${volume_dir}
  echo_done
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

  mysql_pass=$(get_config DB_PASSWORD)
  read_from_input mysql_pass "$(gettext 'Please enter MySQL password')" "" "${mysql_pass}"

  test_mysql_connect ${mysql_host} ${mysql_port} ${mysql_user} ${mysql_pass} ${mysql_db}
  if [[ "$?" != "0" ]]; then
    echo_red "$(gettext 'Failed to connect to database, please reset')"
    echo
    set_mysql
  fi

  set_config DB_HOST ${mysql_host}
  set_config DB_PORT ${mysql_port}
  set_config DB_USER ${mysql_user}
  set_config DB_PASSWORD ${mysql_pass}
  set_config DB_NAME ${mysql_db}
  set_config USE_EXTERNAL_MYSQL 1
}

function set_internal_mysql() {
  set_config USE_EXTERNAL_MYSQL 0
  password=$(get_config DB_PASSWORD)
  if [[ -z "${password}" ]]; then
    DB_PASSWORD=$(random_str 26)
    set_config DB_PASSWORD ${DB_PASSWORD}
  fi
  user=$(get_config DB_USER)
  if [[ "${user}" != "root" ]]; then
    DB_USER=root
    set_config DB_USER ${DB_USER}
  fi
}

function set_mysql() {
  echo_yellow "\n4. $(gettext 'Configure MySQL')"
  use_external_mysql=$(get_config USE_EXTERNAL_MYSQL)
  confirm="n"
  if [[ "${use_external_mysql}" == "1" ]]; then
    confirm="y"
  fi
  read_from_input confirm "$(gettext 'Do you want to use external MySQL')?" "y/n" "${confirm}"

  if [[ "${confirm}" == "y" ]]; then
    set_external_mysql
  else
    set_internal_mysql
  fi
  echo_done
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

  test_redis_connect ${redis_host} ${redis_port} ${redis_password}
  if [[ "$?" != "0" ]]; then
    echo_red "$(gettext 'Failed to connect to redis, please reset')"
    echo
    set_redis
  fi

  set_config REDIS_HOST ${redis_host}
  set_config REDIS_PORT ${redis_port}
  set_config REDIS_PASSWORD ${redis_password}
  set_config USE_EXTERNAL_REDIS 1
}

function set_internal_redis() {
  set_config USE_EXTERNAL_REDIS 0
  password=$(get_config REDIS_PASSWORD)
  if [[ -z "${password}" ]]; then
    REDIS_PASSWORD=$(random_str 26)
    set_config REDIS_PASSWORD "${REDIS_PASSWORD}"
  fi
}

function set_redis() {
  echo_yellow "\n5. $(gettext 'Configure Redis')"
  use_external_redis=$(get_config USE_EXTERNAL_REDIS)
  confirm="n"
  if [[ "${use_external_redis}" == "1" ]]; then
    confirm="y"
  fi
  read_from_input confirm "$(gettext 'Do you want to use external Redis')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    set_external_redis
  else
    set_internal_redis
  fi
  echo_done
}

function set_service_port() {
  echo_yellow "\n6. $(gettext 'Configure External Port')"
  http_port=$(get_config HTTP_PORT)
  ssh_port=$(get_config SSH_PORT)
  rdp_port=$(get_config RDP_PORT)
  use_xpack=$(get_config USE_XPACK)
  confirm="n"
  read_from_input confirm "$(gettext 'Do you need to customize the JumpServer external port')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    read_from_input http_port "$(gettext 'JumpServer web port')" "" "${http_port}"
    set_config HTTP_PORT ${http_port}

    read_from_input ssh_port "$(gettext 'JumpServer ssh port')" "" "${ssh_port}"
    set_config SSH_PORT ${ssh_port}

    if [[ "${use_xpack}" == "1" ]]; then
      read_from_input rdp_port "$(gettext 'JumpServer rdp port')" "" "${rdp_port}"
      set_config RDP_PORT ${rdp_port}
    fi
  fi
  echo_done
}

function init_db() {
  echo_yellow "\n7. $(gettext 'Init JumpServer Database')"
  use_external_mysql=$(get_config USE_EXTERNAL_MYSQL)
  db_host=$(get_config DB_HOST)
  use_ipv6=$(get_config USE_IPV6)
  cmd="docker-compose -f ./compose/docker-compose-redis.yml"
  if [[ "${use_external_mysql}" == "0" ]]; then
    if [[ "${db_host}" == "mysql" ]]; then
      cmd="${cmd} -f ./compose/docker-compose-mysql.yml -f ./compose/docker-compose-init-mysql.yml"
    else
      cmd="${cmd} -f ./compose/docker-compose-mariadb.yml -f ./compose/docker-compose-init-mariadb.yml"
    fi
  fi
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd="${cmd} -f compose/docker-compose-network.yml"
  else
    cmd="${cmd} -f compose/docker-compose-network_ipv6.yml"
  fi
  ${cmd} up -d
  if ! perform_db_migrations; then
    re_code="1"
  fi
  echo
  ${cmd} down
  echo
  if [[ "${re_code}" ]]; then
    log_error "$(gettext 'Failed to change the table structure')!"
    exit 1
  else
    echo_done
  fi
}

function main() {
  set_network
  set_secret_key
  set_volume_dir
  set_mysql
  set_redis
  set_service_port
  init_db
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
