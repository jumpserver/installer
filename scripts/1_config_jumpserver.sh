#!/bin/bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR=$(dirname ${BASE_DIR})

# shellcheck source=./util.sh
. "${BASE_DIR}/utils.sh"

function set_external_mysql() {
  mysql_host=$(get_config DB_HOST)
  read_from_input mysql_host "$(gettext -s 'Please enter MySQL server IP')" "" "${mysql_host}"

  mysql_port=$(get_config DB_PORT)
  read_from_input mysql_port "$(gettext -s 'Please enter MySQL server port')" "" "${mysql_port}"

  mysql_db=$(get_config DB_NAME)
  read_from_input mysql_db "$(gettext -s 'Please enter MySQL database name')" "" "${mysql_db}"

  mysql_user=$(get_config DB_USER)
  read_from_input mysql_user "$(gettext -s 'Please enter MySQL username')" "" "${mysql_user}"

  mysql_pass=$(get_config DB_PASSWORD)
  read_from_input mysql_pass "$(gettext -s 'Please enter MySQL password')" "" "${mysql_pass}"

  test_mysql_connect ${mysql_host} ${mysql_port} ${mysql_user} ${mysql_pass} ${mysql_db}
  if [[ "$?" != "0" ]]; then
    echo_red "测试连接数据库失败, 请重新设置"
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
    set_config MYSQL_ROOT_PASSWORD ${DB_PASSWORD}
  fi
}

function set_mysql() {
  sleep 0.1
  echo_yellow "\n7. $(gettext -s 'Configure MySQL')"
  use_external_mysql=$(get_config USE_EXTERNAL_MYSQL)
  if [[ "$use_external_mysql" == "1" ]]; then
    confirm="y"
  else
    confirm="n"
  fi
  read_from_input confirm "$(gettext -s 'Do you want to use external MySQL')?" "y/n" "${confirm}"

  if [[ "${confirm}" == "y" ]]; then
    set_external_mysql
  else
    set_internal_mysql
  fi
  echo_done
}

function set_external_redis() {
  redis_host=$(get_config REDIS_HOST)
  read_from_input redis_host "$(gettext -s 'Please enter Redis server IP')" "" "${redis_host}"

  redis_port=$(get_config REDIS_PORT)
  read_from_input redis_port "$(gettext -s 'Please enter Redis server port')" "" "${redis_port}"

  redis_password=$(get_config REDIS_PASSWORD)
  read_from_input redis_password "$(gettext -s 'Please enter Redis password')" "" "${redis_password}"

  test_redis_connect ${redis_host} ${redis_port} ${redis_password}
  if [[ "$?" != "0" ]]; then
    echo_red "测试连接 Redis 失败, 请重新设置"
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
  echo_yellow "\n8. $(gettext -s 'Configure Redis')"
  use_external_redis=$(get_config USE_EXTERNAL_REDIS)
  if [[ "$use_external_redis" == "1" ]]; then
    confirm="y"
  else
    confirm="n"
  fi
  read_from_input confirm "$(gettext -s 'Do you want to use external Redis')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    set_external_redis
  else
    set_internal_redis
  fi
  echo_done
}

function set_secret_key() {
  echo_yellow "\n5. $(gettext -s 'Configure Private Key')"
  # 生成随机的 SECRET_KEY 和 BOOTSTRAP_KEY
  secret_key=$(get_config SECRET_KEY)
  if [[ -z "${secret_key}" ]]; then
    secret_key=$(random_str 49)
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
  echo_yellow "\n6. $(gettext -s 'Configure Persistent Directory')"
  echo "$(gettext -s 'To modify the persistent directory such as logs video, you can select your largest disk and create a directory in it, such as') /opt/jumpserver"
  echo "$(gettext -s 'Note: you can not change it after installation, otherwise the database may be lost')"
  echo
  df -h | grep -v map | grep -v devfs | grep -v tmpfs | grep -v "overlay" | grep -v "shm"
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -z "${volume_dir}" ]]; then
    volume_dir="/opt/jumpserver"
  fi
  echo
  read_from_input volume_dir "$(gettext -s 'Persistent storage directory')" "" "${volume_dir}"

  if [[ ! -d "${volume_dir}" ]]; then
    mkdir -p ${volume_dir}
  fi
  set_config VOLUME_DIR ${volume_dir}
  echo_done
}

function prepare_config() {
  cwd=$(pwd)
  cd "${PROJECT_DIR}" || exit

  config_dir=$(dirname "${CONFIG_FILE}")
  echo_yellow "1. $(gettext -s 'Check Configuration File')"
  echo "$(gettext -s 'Path to Configuration file'): ${CONFIG_FILE}"
  if [[ ! -d ${config_dir} ]]; then
    config_dir_parent=$(dirname "${config_dir}")
    mkdir -p "${config_dir_parent}"
    cp config-example.txt "${CONFIG_FILE}"
  fi
  if [[ ! -f ${CONFIG_FILE} ]]; then
    cp config-example.txt "${CONFIG_FILE}"
  fi
  if [[ ! -f .env ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi
  for d in $(ls config_init | grep -v README.md); do
    if [ ! -d "${config_dir}/${d}" ]; then
      \cp -rf config_init/${d} ${config_dir}
    fi
  done

  echo_done

  nginx_cert_dir="${config_dir}/nginx/cert"
  echo_yellow "\n2. $(gettext -s 'Configure Nginx')"
  echo "$(gettext -s 'configuration file'): ${nginx_cert_dir}"
  # 迁移 nginx 的证书
  if [[ ! -d ${nginx_cert_dir} ]]; then
    mkdir -p ${nginx_cert_dir}
    cp -R "${PROJECT_DIR}/config_init/nginx/cert" "${nginx_cert_dir}"
  fi
  echo_done

  backup_dir="${config_dir}/backup"
  mkdir -p "${backup_dir}"
  now=$(date +'%Y-%m-%d_%H-%M-%S')
  backup_config_file="${backup_dir}/config.txt.${now}"
  echo_yellow "\n3. $(gettext -s 'Backup Configuration File')"
  cp "${CONFIG_FILE}" "${backup_config_file}"
  echo "$(gettext -s 'Back up to') ${backup_config_file}"
  echo_done

  # IPv6 支持
  echo_yellow "\n4. $(gettext -s 'Configure Network')"
  use_ipv6=$(get_config USE_IPV6)
  if [[ "$use_ipv6" == "1" ]]; then
    confirm="y"
  else
    confirm="n"
  fi
  read_from_input confirm "$(gettext -s 'Do you want to support IPv6')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]];then
    set_config USE_IPV6 1
  fi
  echo_done

  cd "${cwd}" || exit
}

function set_jumpserver() {
  prepare_config
  set_secret_key
  set_volume_dir
}

function main() {
  set_jumpserver
  set_mysql
  set_redis
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
