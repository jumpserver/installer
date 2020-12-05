#!/bin/bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR=$(dirname ${BASE_DIR})

# shellcheck source=./util.sh
source "${BASE_DIR}/utils.sh"


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

    test_mysql_connect ${mysql_host} ${mysql_port} ${mysql_user} ${mysql_pass} ${mysql_db}
    if [[ "$?" != "0" ]];then
        echo "测试连接数据库失败, 可以 Ctrl-C 退出程序重新设置，或者继续"
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
    sleep 0.1
    echo_green "\n>>> 四、 配置MySQL"
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

    test_redis_connect ${redis_host} ${redis_port} ${redis_password}
    if [[ "$?" != "0" ]];then
       echo "测试连接Redis失败, 可以 Ctrl-C 退出程序重新设置，或者继续"
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
  echo_green "\n>>> 五、 配置Redis"
  use_external_redis="n"
  read_from_input use_external_redis "是否使用外部redis " "y/n" "${use_external_redis}"
  if [[ "${use_external_redis}" == "y" ]];then
      set_external_redis
  else
      set_internal_redis
  fi
}

function set_secret_key() {
    echo_yellow "\n5. 自动生成加密密钥"
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
    echo_yellow "\n6. 配置持久化目录 "
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
    cd "${PROJECT_DIR}" || exit

    config_dir=$(dirname "${CONFIG_FILE}")
    echo_yellow "1. 检查配置文件 ${config_dir}"
    if [[ ! -d ${config_dir} ]];then
        config_dir_parent=$(dirname "${config_dir}")
        mkdir -p "${config_dir_parent}"
        cp -r config_init "${config_dir}"
        cp config-example.txt "${CONFIG_FILE}"
    fi
    if [[ ! -f ${CONFIG_FILE} ]];then
        cp config-example.txt "${CONFIG_FILE}"
    fi

    nginx_cert_dir="${config_dir}/nginx/cert"
    echo_yellow "\n2. 配置 Nginx 证书 ${nginx_cert_dir}"
    # 迁移 nginx 的证书
    if [[ ! -d ${nginx_cert_dir} ]];then
      cp -R "${PROJECT_DIR}/config_init/nginx/cert" "${nginx_cert_dir}"
    fi

    # .env 会被docker compose使用
    echo_yellow "\n3. 检查变量文件 .env"
    if [[ ! -f .env ]];then
        ln -s "${CONFIG_FILE}" .env
    fi
    backup_dir="${config_dir}/backup"
    mkdir -p "${backup_dir}"
    now=$(date +'%Y-%m-%d_%H-%M-%S')

    backup_config_file="${backup_dir}/config.txt.${now}"
    echo_yellow "\n4. 备份配置文件 ${backup_config_file}"
    cp "${CONFIG_FILE}" "${backup_config_file}"
    cd "${cwd}" || exit
}

function set_jumpserver() {
    echo_green ">>> 三、配置JumpServer"
    prepare_config
    set_secret_key
    set_volume_dir
}

function finish() {
    echo_green "\n>>> 六、安装完成了"
    HOST=$(ip a | grep -A 7 -E 'eth[0-9]+|ens[0-9]+' | grep inet | grep -v inet6|awk '{print $2}'|tr -d "addr:" | head -1 | awk -F/ '{ print $1 }')
    HTTP_PORT=$(get_config HTTP_PORT)
    HTTPS_PORT=$(get_config HTTPS_PORT)
    SSH_PORT=$(get_config SSH_PORT)

    echo_yellow "1. 可以使用如下命令启动, 然后访问"
    echo "./jmsctl.sh start"

    echo_yellow "\n2. 其它一些管理命令"
    echo "./jmsctl.sh stop"
    echo "./jmsctl.sh restart"
    echo "./jmsctl.sh backup"
    echo "./jmsctl.sh upgrade"
    echo "更多还有一些命令，你可以 ./jmsctl.sh --help来了解"

    echo_yellow "\n3. 访问 Web 后台页面"
    echo "http://${HOST}:${HTTP_PORT}"
    echo "https://${HOST}:${HTTPS_PORT}"

    echo_yellow "\n4. ssh/sftp 访问"
    echo "ssh admin@${HOST} -p${SSH_PORT}"
    echo "sftp -P${SSH_PORT} admin@${HOST}"

    echo_yellow "\n5. 更多信息"
    echo "我们的文档: https://docs.jumpserver.org/"
    echo "我们的官网: https://www.jumpserver.org/"
    echo -e "\n\n"
}

function main(){
    set_jumpserver
    set_mysql
    set_redis
    finish
}

if [[  "$0" = "$BASH_SOURCE"  ]];then
  main
fi
