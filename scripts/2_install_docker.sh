#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"
. "${BASE_DIR}/0_prepare.sh"

DOCKER_CONFIG="/etc/docker/daemon.json"
docker_copy_failed=0

cd "${BASE_DIR}" || exit 1

function copy_docker() {
  \cp -f ./docker/* /usr/local/bin/
  \cp -f ./docker.service /etc/systemd/system/
}

function install_docker() {
  if [[ ! -f ./docker/dockerd ]]; then
    prepare_docker_bin
  fi
  if [[ ! -f ./docker/dockerd ]]; then
    echo_red "Error: $(gettext 'Docker program does not exist')"
    exit 1
  fi

  docker_exist=1
  docker_version_match=1
  old_docker_md5=$(get_file_md5 /usr/local/bin/dockerd)
  new_docker_md5=$(get_file_md5 ./docker/dockerd)

  if [[ ! -f "/usr/local/bin/dockerd" ]]; then
    docker_exist=0
  elif [[ "${old_docker_md5}" != "${new_docker_md5}" ]]; then
    docker_version_match=0
  fi

  if [[ "${docker_exist}" != "1" ]]; then
    copy_docker
  elif [[ "${docker_version_match}" != "1" ]]; then
    confirm="n"
    read_from_input confirm "$(gettext 'There are updates available currently. Do you want to update')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      copy_docker
    fi
  fi
}

function install_compose() {
  if [[ ! -f ./docker/docker-compose ]]; then
    prepare_compose_bin
  fi
  old_docker_compose_md5=$(get_file_md5 /usr/local/bin/docker-compose)
  new_docker_compose_md5=$(get_file_md5 ./docker/docker-compose)
  if [[ ! -f "/usr/local/bin/docker-compose" || "${old_docker_compose_md5}" != "${new_docker_compose_md5}" ]]; then
    \cp -f ./docker/docker-compose /usr/local/bin/
    chmod +x /usr/local/bin/docker-compose
  fi
}

function check_docker_install() {
  command -v docker >/dev/null || {
    install_docker
  }
}

function check_compose_install() {
  command -v docker-compose >/dev/null || {
    install_compose
  }
  echo_done
}

function set_docker_config() {
  key=$1
  value=$2

  if command -v python >/dev/null; then
    docker_command=python
  elif command -v python2 >/dev/null; then
    docker_command=python2
  elif command -v python3 >/dev/null; then
    docker_command=python3
  else
    return
  fi

  if [[ ! -f "${DOCKER_CONFIG}" ]]; then
    config_dir=$(dirname ${DOCKER_CONFIG})
    if [[ ! -d ${config_dir} ]]; then
      mkdir -p "${config_dir}"
    fi
    echo -e "{\n}" >>${DOCKER_CONFIG}
  fi

"${docker_command}" -c "import json
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
"
}

function config_docker() {
  docker_storage_path=$(get_config DOCKER_DIR "/var/lib/docker")
  if [[ ! -d "${docker_storage_path}" ]]; then
    mkdir -p "${docker_storage_path}"
  fi

  set_docker_config registry-mirrors '["https://hub-mirror.c.163.com", "http://f1361db2.m.daocloud.io"]'
  set_docker_config live-restore "true"
  set_docker_config data-root "${docker_storage_path}"
  set_docker_config log-driver "json-file"
  set_docker_config log-opts '{"max-size": "10m", "max-file": "3"}'
}

function set_network() {
  # IPv6 支持
  use_ipv6=$(get_config USE_IPV6)
  confirm="n"
  if [[ "${use_ipv6}" == "1" ]]; then
    confirm="y"
  fi
  read_from_input confirm "$(gettext 'Do you want to support IPv6')?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    set_docker_config ipv6 "true"
    set_docker_config fixed-cidr-v6 "fc00:1010:1111:100::/64"
    set_docker_config experimental "true"
    set_docker_config ip6tables "true"
    set_config USE_IPV6 1
  fi
}

function check_docker_config() {
  if [[ ! -f "/etc/docker/daemon.json" ]]; then
    config_docker
    set_network
  fi
  echo_done
}

function start_docker() {
  if command -v systemctl >/dev/null; then
    systemctl daemon-reload
    systemctl enable docker
    systemctl start docker
  fi
  if ! docker ps >/dev/null 2>&1; then
    echo_failed
    exit 1
  fi
}

function check_docker_start() {
  prepare_set_redhat_firewalld
  if ! docker ps >/dev/null 2>&1; then
    start_docker
  fi
}

function check_docker_compose() {
  if ! docker-compose -v >/dev/null 2>&1; then
    echo_failed
    exit 1
  fi
  echo_done
}

function main() {
  echo_yellow "1. $(gettext 'Install Docker')"
  check_docker_install
  check_compose_install
  echo_yellow "\n2. $(gettext 'Configure Docker')"
  check_docker_config
  echo_yellow "\n3. $(gettext 'Start Docker')"
  check_docker_start
  check_docker_compose
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
