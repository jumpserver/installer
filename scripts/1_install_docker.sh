#!/bin/bash
BASE_DIR=$(dirname "$0")

# shellcheck source=./util.sh
. "${BASE_DIR}/utils.sh"

# shellcheck source=./0_prepare.sh
. "${BASE_DIR}/0_prepare.sh"

DOCKER_CONFIG="/etc/docker/daemon.json"
docker_exist=0
docker_version_match=1
docker_config_change=0
docker_copy_failed=0

cd "${BASE_DIR}" || exit

function copy_docker() {
   cp ./docker/* /usr/bin/ && cp ./docker.service /etc/systemd/system/ && \
   chmod +x /usr/bin/docker* && chmod 754 /etc/systemd/system/docker.service
   if [[ "$?" != "0" ]];then
       docker_copy_failed=1
   fi
}

function offline_install_docker() {
    echo "1. 安装Docker"
    old_docker_md5=$(get_file_md5 /usr/bin/dockerd)
    new_docker_md5=$(get_file_md5 ./docker/dockerd)

    if [[ -f "/usr/bin/dockerd" ]];then
        docker_exist=1
    elif [[ "${old_docker_md5}" != "${new_docker_md5}" ]];then
        docker_version_match=0
    fi

    if [[ "${docker_exist}" != "1" ]];then
        copy_docker
    elif [[ "${docker_version_match}" != "1" ]];then
        confirm="y"
        read_from_input confirm "已有Docker与本Release包版本不一致, 是否覆盖" "y/n" "${confirm}"
        if [[ "$confirm" == "n" ]];then
            copy_docker
        fi
    fi

    if [[ "${docker_copy_failed}" != "0" ]];then
        echo "Docker 复制失败，可能是已有docker运行，请停止运行的docker重新执行"
        echo "systemctl stop docker"
        exit 1
    fi

    old_docker_compose_md5=$(get_file_md5 /usr/bin/docker-compose)
    new_docker_compose_md5=$(get_file_md5 ./docker/docker-compose)
    if [[ ! -f "/usr/bin/docker-compose" || "${old_docker_compose_md5}" != "${new_docker_compose_md5}" ]];then
        cp ./docker/docker-compose /usr/bin/
        chmod +x /usr/bin/docker-compose
    fi
}

function install_docker() {
    if [[ -f ./docker/dockerd ]];then
      prepare_docker_bin
    fi
    offline_install_docker
}


function set_docker_config() {
   key=$1
   value=$2

   if [[ ! -f "${DOCKER_CONFIG}" ]];then
       config_dir=$(dirname ${DOCKER_CONFIG})
       if [[ ! -d ${config_dir} ]];then
           mkdir -p ${config_dir}
       fi
        echo -e "{\n}" >> ${DOCKER_CONFIG}
   fi
   $(python -c "import json
key = '${key}'
value = '${value}'
try:
    value = json.loads(value)
except:
    pass
filepath = \"${DOCKER_CONFIG}\"
f = open(filepath);
config = json.load(f);
config[key] = value
f.close();
f = open(filepath, 'w');
json.dump(config, f, indent=True, sort_keys=True);
f.close()
")
}


function config_docker(){
    echo "2. 配置Docker"
    if [[ -f '/etc/docker/daemon.json' ]];then
       cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
    fi
    echo "修改Docker镜像容器的默认存储目录，可以找个最大的磁盘, 并创建目录，如 /opt/docker"
    df -h | grep -v map | grep -v devfs | grep -v tmpfs | grep -v "overlay" | grep -v "shm"

    docker_storage_path='/opt/docker'
    read_from_input docker_storage_path "Docker存储目录" '' "${docker_storage_path}"

    if [[ ! -d "${docker_storage_path}" ]];then
        mkdir -p ${docker_storage_path}
    fi
    set_docker_config graph "${docker_storage_path}"
    set_docker_config log-driver "json-file"
    set_docker_config log-opts '{"max-size": "10m", "max-file": "3"}'
    diff /etc/docker/daemon.json /etc/docker/daemon.json.bak &> /dev/null
    if [[ "$?" != "0" ]];then
        docker_config_change=1
    fi
}

function start_docker(){
    echo "3. 启动Docker"
    systemctl daemon-reload
    docker_is_running=$(is_running dockerd)

    if [[ "${docker_is_running}" && "${docker_version_match}" != "1" || "${docker_config_change}" == "1" ]];then
        confirm="y"
        read_from_input confirm "Docker 版本发生改变 或 docker配置文件发生变化，是否要重启" "y/n" "y"
        if [[ "${confirm}" != "n" ]];then
            systemctl restart docker
        fi
    else
        systemctl start docker
    fi
    systemctl enable docker &> /dev/null
}

function main(){
    echo ""
    echo ">>> 安装配置Docker"
    if [[ "${OS}" == 'Darwin' ]];then
        echo "MacOS skip install docker"
        return
    fi
    which docker >/dev/null 2>&1
    if [ $? -ne 0 ];then
        install_docker
    fi
    if [ ! -f "/etc/docker/daemon.json" ]; then
        config_docker
    fi
    if [ ! "$(systemctl status docker | grep Active | grep running)" ]; then
        start_docker
    fi
}

main
