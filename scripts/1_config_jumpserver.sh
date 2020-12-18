#!/bin/bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR=$(dirname ${BASE_DIR})

# shellcheck source=./util.sh
source "${BASE_DIR}/utils.sh"

function set_external_mysql() {
  mysql_host=""
  read_from_input mysql_host "请输入mysql的主机地址" "" "${mysql_host}"

  mysql_port="3306"
  read_from_input mysql_port "请输入mysql的端口" "" "${mysql_port}"

  mysql_db="jumpserver"
  read_from_input mysql_db "请输入mysql的数据库(事先做好授权)" "" "${mysql_db}"

  mysql_user=""
  read_from_input mysql_user "请输入mysql的用户名" "" "${mysql_user}"

  mysql_pass=""
  read_from_input mysql_pass "请输入mysql的密码" "" "${mysql_pass}"

#  test_mysql_connect ${mysql_host} ${mysql_port} ${mysql_user} ${mysql_pass} ${mysql_db}
#  if [[ "$?" != "0" ]]; then
#    echo "测试连接数据库失败, 可以 Ctrl-C 退出程序重新设置，或者继续"
#  fi
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
  echo_yellow "\n7. 配置MySQL"
  use_external_mysql="n"
  read_from_input use_external_mysql "是否使用外部mysql" "y/n" "${use_external_mysql}"

  if [[ "${use_external_mysql}" == "y" ]]; then
    set_external_mysql
  else
    set_internal_mysql
  fi
  echo_done
}

function set_external_redis() {
  redis_host=""
  read_from_input redis_host "请输入redis的主机地址" "" "${redis_host}"

  redis_port=6379
  read_from_input redis_port "请输入redis的端口" "" "${redis_port}"

  redis_password=""
  read_from_input redis_password "请输入redis的密码" "" "${redis_password}"

#  test_redis_connect ${redis_host} ${redis_port} ${redis_password}
#  if [[ "$?" != "0" ]]; then
#    echo "测试连接Redis失败, 可以 Ctrl-C 退出程序重新设置，或者继续"
#  fi
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
  echo_yellow "\n8. 配置Redis"
  use_external_redis="n"
  read_from_input use_external_redis "是否使用外部redis " "y/n" "${use_external_redis}"
  if [[ "${use_external_redis}" == "y" ]]; then
    set_external_redis
  else
    set_internal_redis
  fi
  echo_done
}

function set_secret_key() {
  echo_yellow "\n5. 自动生成加密密钥"
  # 生成随机的 SECRET_KEY 和 BOOTSTRAP_KEY
  if [[ -z "$(get_config SECRET_KEY)" ]]; then
    SECRETE_KEY=$(random_str 49)
    set_config SECRET_KEY ${SECRETE_KEY}
  fi
  if [[ -z "$(get_config BOOTSTRAP_TOKEN)" ]]; then
    BOOTSTRAP_TOKEN=$(random_str 16)
    set_config BOOTSTRAP_TOKEN ${BOOTSTRAP_TOKEN}
  fi
  echo_done
}

function set_volume_dir() {
  echo_yellow "\n6. 配置持久化目录 "
  echo "修改日志录像等持久化的目录，可以找个最大的磁盘，并创建目录，如 /opt/jumpserver"
  echo "注意: 安装完后不能再更改, 否则数据库可能丢失"
  echo
  df -h | grep -v map | grep -v devfs | grep -v tmpfs | grep -v "overlay" | grep -v "shm"
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -z "${volume_dir}" ]]; then
    volume_dir="/opt/jumpserver"
  fi
  echo
  read_from_input volume_dir "设置持久化卷存储目录" "" "${volume_dir}"

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
  echo "各组件使用环境变量式配置文件，而不是 yaml 格式, 配置名称与之前保持一致"
  echo "配置文件位置: ${CONFIG_FILE}"
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

  nginx_cert_dir="${config_dir}/nginx/cert"
  echo_yellow "\n2. 配置 Nginx 证书"
  echo "证书位置在: ${nginx_cert_dir}"
  # 迁移 nginx 的证书
  if [[ ! -d ${nginx_cert_dir} ]]; then
    cp -R "${PROJECT_DIR}/config_init/nginx/cert" "${nginx_cert_dir}"
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

  # IPv6 支持
  echo_yellow "\n4. 配置网络"
  confirm="n"
  read_from_input confirm "需要支持 IPv6 吗?" "y/n" "${confirm}"
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
