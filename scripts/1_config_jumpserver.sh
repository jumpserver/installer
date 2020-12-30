#!/bin/bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR=$(dirname ${BASE_DIR})

# shellcheck source=./util.sh
source "${BASE_DIR}/utils.sh"

function set_external_mysql() {
  mysql_host=$(get_config DB_HOST)
  if [[ -z "${mysql_host}" ]]; then
    read_from_input mysql_host "请输入mysql的主机地址" "" "${mysql_host}"
    set_config DB_HOST ${mysql_host}
  fi

  mysql_port=$(get_config DB_PORT)
  if [[ -z "${mysql_port}" ]]; then
    read_from_input mysql_port "请输入mysql的端口" "" "${mysql_port}"
    set_config DB_PORT ${mysql_port}
  fi

  mysql_user=$(get_config DB_DB_USER)
  if [[ -z "${mysql_user}" ]]; then
    read_from_input mysql_user "请输入mysql的用户名" "" "${mysql_user}"
    set_config DB_USER ${mysql_user}
  fi

  mysql_pass=$(get_config DB_PASSWORD)
  if [[ -z "${mysql_pass}" ]]; then
    read_from_input mysql_pass "请输入mysql的密码" "" "${mysql_pass}"
    set_config DB_PASSWORD ${mysql_pass}
  fi

  mysql_db=$(get_config DB_NAME)
  if [[ -z "${mysql_db}" ]]; then
    read_from_input mysql_db "请输入mysql的数据库(事先做好授权)" "" "${mysql_db}"
    set_config DB_NAME ${mysql_db}
  fi

#  test_mysql_connect ${mysql_host} ${mysql_port} ${mysql_user} ${mysql_pass} ${mysql_db}
#  if [[ "$?" != "0" ]]; then
#    echo "测试连接数据库失败, 可以 Ctrl-C 退出程序重新设置，或者继续"
#  fi
}

function set_internal_mysql() {
  password=$(get_config DB_PASSWORD)
  if [[ -z "${password}" ]]; then
    DB_PASSWORD=$(random_str 26)
    set_config DB_PASSWORD ${DB_PASSWORD}
    set_config MYSQL_ROOT_PASSWORD ${DB_PASSWORD}
  fi
}

function set_mysql() {
  sleep 0.1
  echo_yellow "\n6. 配置 MySQL"
  db_host=$(get_config DB_HOST)
  if [[ "${db_host}" == "mysql" ]]; then
    set_internal_mysql
  else
    set_external_mysql
  fi
  echo_done
}

function set_external_redis() {
  redis_host=$(get_config REDIS_HOST)
  if [[ -z "${redis_host}" ]]; then
    read_from_input redis_host "请输入redis的主机地址" "" "${redis_host}"
    set_config REDIS_HOST ${redis_host}
  fi

  redis_port=$(get_config REDIS_PORT)
  if [[ -z "${redis_port}" ]]; then
    read_from_input redis_port "请输入redis的端口" "" "${redis_port}"
    set_config REDIS_PORT ${redis_port}
  fi

  redis_password=$(get_config REDIS_PASSWORD)
  if [[ -z "${redis_password}" ]]; then
    read_from_input redis_password "请输入redis的密码" "" "${redis_password}"
    set_config REDIS_PASSWORD ${redis_password}
  fi

#  test_redis_connect ${redis_host} ${redis_port} ${redis_password}
#  if [[ "$?" != "0" ]]; then
#    echo "测试连接Redis失败, 可以 Ctrl-C 退出程序重新设置，或者继续"
#  fi
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
  echo_yellow "\n7. 配置 Redis"
  redis_host=$(get_config REDIS_HOST)
  if [[ "${redis_host}" == "redis" ]]; then
    set_internal_redis
  else
    set_external_redis
  fi
  echo_done
}

function set_secret_key() {
  echo_yellow "\n4. 配置加密密钥"
  # 生成随机的 SECRET_KEY 和 BOOTSTRAP_KEY
  if [[ -z "$(get_config SECRET_KEY)" ]]; then
    SECRETE_KEY=$(random_str 49)
    echo "自动生成 SECRETE_KEY     ${SECRETE_KEY}"
    set_config SECRET_KEY ${SECRETE_KEY}
  fi
  if [[ -z "$(get_config BOOTSTRAP_TOKEN)" ]]; then
    BOOTSTRAP_TOKEN=$(random_str 16)
    echo "自动生成 BOOTSTRAP_TOKEN ${BOOTSTRAP_TOKEN}"
    set_config BOOTSTRAP_TOKEN ${BOOTSTRAP_TOKEN}
  fi
  echo_done
}

function set_volume_dir() {
  echo_yellow "\n5. 配置持久化目录 "
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -z "${volume_dir}" ]]; then
    read_from_input volume_dir "设置持久化存储目录" "" "${volume_dir}"
  fi
  echo "持久化存储目录 ${volume_dir}"
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
  echo_yellow "1. 检查配置文件"
  echo "配置文件位置 ${CONFIG_FILE}"
  if [[ ! -d ${config_dir} ]]; then
    config_dir_parent=$(dirname "${config_dir}")
    mkdir -p "${config_dir_parent}"
    cp -r config_init "${config_dir}"
    cp config-example.txt "${CONFIG_FILE}"
  fi
  if [[ ! -f ${CONFIG_FILE} ]]; then
    cp config-example.txt "${CONFIG_FILE}"
  fi
  if [[ ! -f .env ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi
  echo_done

  nginx_conf_dir="${config_dir}/nginx"
  nginx_cert_dir="${config_dir}/nginx/cert"
  echo_yellow "\n2. 配置 Nginx"
  echo "配置文件 ${nginx_conf_dir}"
  # 迁移 nginx.conf
  if [[ ! -d ${nginx_conf_dir} ]]; then
    mkdir -p ${nginx_cert_dir}
  fi
  if [[ ! -f "${nginx_conf_dir}/http_server.conf" ]]; then
    cp "${PROJECT_DIR}/compose/config_static/http_server.conf" "${nginx_conf_dir}"
  fi
  if [[ ! -f "${nginx_conf_dir}/lb_http_server.conf" ]]; then
    cp "${PROJECT_DIR}/config_init/nginx/lb_http_server.conf" "${nginx_conf_dir}"
  fi
  if [[ ! -f "${nginx_conf_dir}/lb_ssh_server.conf" ]]; then
    cp "${PROJECT_DIR}/config_init/nginx/lb_ssh_server.conf" "${nginx_conf_dir}"
  fi
  echo "证书位置 ${nginx_cert_dir}"
  # 迁移 nginx 的证书
  if [[ ! -f ${nginx_cert_dir}/server.crt ]]; then
    cp "${PROJECT_DIR}/config_init/nginx/cert/server.crt" "${nginx_cert_dir}"
  fi
  if [[ ! -f ${nginx_cert_dir}/server.key ]]; then
    cp "${PROJECT_DIR}/config_init/nginx/cert/server.key" "${nginx_cert_dir}"
  fi
  echo_done

  backup_dir="${config_dir}/backup"
  mkdir -p "${backup_dir}"
  now=$(date +'%Y-%m-%d_%H-%M-%S')
  backup_config_file="${backup_dir}/config.txt.${now}"
  echo_yellow "\n3. 备份配置文件"
  cp "${CONFIG_FILE}" "${backup_config_file}"
  echo "备份至 ${backup_config_file}"
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
