#!/bin/bash
# Copyright (c) 2014-2019 Beijing Duizhan Tech, Inc., All rights reserved.
# Author: Jumpserver Team
# Mail: support@fit2cloud.com
#

BASE_DIR=$(cd "$(dirname "$0")";pwd)
PROJECT_DIR=$(dirname ${BASE_DIR})
source ${BASE_DIR}/utils.sh


function set_external_mysql(){
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

    #test_mysql_connect ${mysql_host} ${mysql_port} ${mysql_user} ${mysql_pass} ${mysql_db}
    if [[ "$?" != "0" ]];then
        echo "测试连接数据库失败, 请重新设置"
        set_external_mysql
        return
    fi
    set_config DB_HOST ${mysql_host}
    set_config DB_PORT ${mysql_port}
    set_config DB_USER ${mysql_user}
    set_config DB_PASSWORD ${mysql_pass}
    set_config DB_NAME ${mysql_db}
    set_config USE_EXTERNAL_MYSQL 1
}

function set_internal_mysql(){
    set_config USE_EXTERNAL_MYSQL 0
    password=$(get_config DB_PASSWORD)
    if [[ -z "${password}" ]];then
        DB_PASSWORD=$(random_str 26)
        set_config DB_PASSWORD ${DB_PASSWORD}
        set_config MYSQL_ROOT_PASSWORD ${DB_PASSWORD}
    fi
}


function set_mysql() {
    echo ">>> 配置MySQL"
    use_external_mysql="n"
    read_from_input use_external_mysql "是否使用外部mysql" "y/n" "${use_external_mysql}"

    if [[ "${use_external_mysql}"  == "y" ]];then
        set_external_mysql
    else
        set_internal_mysql
    fi
}

function set_external_redis() {
    redis_host=""
    read_from_input redis_host "请输入redis的主机地址" "" "${redis_host}"

    redis_port=6379
    read_from_input redis_port "请输入redis的端口" "" "${redis_port}"

    redis_password=""
    read_from_input redis_password "请输入redis的密码" "" "${redis_password}"

    #test_redis_connect ${redis_host} ${redis_port} ${redis_password}
    if [[ "$?" != "0" ]];then
       echo "测试连接Redis失败, 请重新设置"
       set_external_redis
       return
    fi
    set_config REDIS_HOST ${redis_host}
    set_config REDIS_PORT ${redis_port}
    set_config REDIS_PASSWORD ${redis_password}
    set_config USE_EXTERNAL_REDIS 1
}

function set_internal_redis() {
    set_config USE_EXTERNAL_REDIS 0
    password=$(get_config REDIS_PASSWORD)
    if [[ -z "${password}" ]];then
        REDIS_PASSWORD=$(random_str 26)
        set_config REDIS_PASSWORD "${REDIS_PASSWORD}"
    fi
}

function set_redis(){
  echo ">>> 配置Redis"
  use_external_redis="n"
  read_from_input use_external_redis "是否使用外部redis " "y/n" "${use_external_redis}"
  if [[ "${use_external_redis}" == "y" ]];then
      set_external_redis
  else
      set_internal_redis
  fi
}

function set_secret_key() {
    # 生成随机的 SECRET_KEY 和 BOOTSTRAP_KEY
    if [[ -z "$(get_config SECRET_KEY)" ]];then
        SECRETE_KEY=$(random_str 49)
        set_config SECRET_KEY ${SECRETE_KEY}
    fi
    if [[ -z "$(get_config BOOTSTRAP_TOKEN)" ]];then
        BOOTSTRAP_TOKEN=$(random_str 16)
        set_config BOOTSTRAP_TOKEN ${BOOTSTRAP_TOKEN}
    fi
}

function set_volume_dir() {
    echo "修改日志录像等持久化的目录，可以找个最大的磁盘，并创建目录，如 /opt/jumpserver"
    echo "注意: 安装完后不能再更改, 否则数据库可能丢失"
    df -h | grep -v map | grep -v devfs | grep -v tmpfs | grep -v "overlay" | grep -v "shm"
    volume_dir=$(get_config VOLUME_DIR)
    if [[ -z "${volume_dir}" ]];then
        volume_dir="/opt/jumpserver"
    fi
    read_from_input volume_dir "设置持久化卷存储目录" "" "${volume_dir}"

    if [[ ! -d "${volume_dir}" ]];then
        mkdir -p ${volume_dir}
    fi
    set_config VOLUME_DIR ${volume_dir}
}

function prepare_config() {
    cwd=$(pwd)
    cd ${PROJECT_DIR}

    if [[ ! -f ${CONFIG_FILE} ]];then
        mkdir -p $(dirname ${CONFIG_FILE})
        cp config-example.txt ${CONFIG_FILE}
    fi
    if [[ ! -d /opt/jumpserver/config/nginx/cert ]];then
      cp -R nginx/cert /opt/jumpserver/config/nginx/
    fi

    if [[ ! -f .env ]];then
        ln -s ${CONFIG_FILE} .env
    fi
    mkdir -p /opt/jumpserver/config/backup
    now=$(date +'%Y-%m-%d_%H-%M-%S')
    cp ${CONFIG_FILE} /opt/jumpserver/config/backup/config.txt.${now}
    cd ${cwd}
}

function set_jumpserver() {
    echo ">>> 配置Jumpserver"
    prepare_config
    set_secret_key
    set_volume_dir
}

function main(){
    set_jumpserver
    set_mysql
    set_redis

    HTTP_PORT=$(get_config HTTP_PORT)
    HTTPS_PORT=$(get_config HTTPS_PORT)
    SSH_PORT=$(get_config SSH_PORT)
    echo "设置完成，可以使用如下命令启动, 然后访问"
    echo "./jmsctl.sh start"
    echo
    echo "http://<HOST>:${HTTP_PORT}"
    echo "https://<HOST>:${HTTPS_PORT}"
    echo "ssh admin@<HOST> -p${SSH_PORT}"
}

main
