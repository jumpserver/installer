#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/0_prepare.sh"

DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"

cd "${BASE_DIR}" || exit 1

function copy_docker() {
  if [[ ! -d "/usr/local/bin" ]]; then
    mkdir -p /usr/local/bin
  fi
  tar --no-same-owner --strip-components=1 -xf "${BASE_DIR}/docker/docker.tar.gz" -C /usr/local/bin/ || {
    echo_red "$(gettext 'Failed to extract docker.tar.gz')"
    exit 1
  }
  \cp -f "${BASE_DIR}/docker/docker.service" /etc/systemd/system/
}

function install_docker() {
  if [[ ! -f ${BASE_DIR}/docker/docker.tar.gz ]]; then
    prepare_docker_bin
  fi
  if [[ ! -f ${BASE_DIR}/docker/docker.tar.gz ]]; then
    echo_red "Error: $(gettext 'Docker program does not exist')"
    exit 1
  fi
  copy_docker
}

function check_docker_install() {
  docker version &>/dev/null || {
    if check_root; then
      if [[ ! -f "/usr/local/bin/dockerd" ]]; then
        install_docker
      fi
    else
      log_warn "$(gettext 'Permission denied. pass...')"
    fi
  }
}

function check_compose_install() {
  # An explicit plugin path is supplied only after an upgrade is confirmed.
  local plugin=${1:-} package="${BASE_DIR}/docker/docker-compose" staged version
  if [[ -z "${plugin}" ]]; then
    if docker compose version &>/dev/null; then
      echo_done
      return 0
    fi
    if check_root; then
      plugin="/usr/local/libexec/docker/cli-plugins/docker-compose"
    else
      plugin="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins/docker-compose"
    fi
    if [[ -e "${plugin}" || -L "${plugin}" ]]; then
      log_error "Docker Compose is unavailable with the existing plugin at ${plugin}"
      return 1
    fi
  fi

  if [[ ! -f "${package}" ]]; then
    prepare_compose_bin || return 1
  fi
  mkdir -p "${plugin%/*}" || return 1
  staged=$(mktemp "${plugin}.XXXXXX") || return 1
  if ! install -m 0755 "${package}" "${staged}"; then
    rm -f "${staged}"
    return 1
  fi
  if [[ -n "${1:-}" ]]; then
    if ! version=$("${staged}" version --short) || [[ "${version#v}" != "${DOCKER_COMPOSE_VERSION#v}" ]]; then
      rm -f "${staged}"
      log_error "Invalid Docker Compose package: expected ${DOCKER_COMPOSE_VERSION}"
      return 1
    fi
  fi
  mv -f "${staged}" "${plugin}" || { rm -f "${staged}"; return 1; }
  if [[ -z "${1:-}" ]]; then
    check_docker_compose
  else
    echo_done
  fi
}

function set_docker_config() {
  key=$1
  value=$2

  local docker_command
  docker_command=$(get_python) || return 0

  if [[ ! -f "${DOCKER_DAEMON_CONFIG}" ]]; then
    config_dir=$(dirname ${DOCKER_DAEMON_CONFIG})
    if [[ ! -d ${config_dir} ]]; then
      mkdir -p "${config_dir}"
    fi
    echo -e "{\n}" >>${DOCKER_DAEMON_CONFIG}
  fi

"${docker_command}" -c "import json
key = '${key}'
value = '${value}'
try:
    value = json.loads(value)
except:
    pass
filepath = \"${DOCKER_DAEMON_CONFIG}\"
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
  if check_root; then
    if [[ ! -f "/etc/docker/daemon.json" ]]; then
      config_docker
      set_network
    fi
    echo_done
  else
    log_warn "$(gettext 'Permission denied. pass...')"
  fi
}

function start_docker() {
  if command -v systemctl&>/dev/null; then
    systemctl daemon-reload
    systemctl enable docker
    systemctl start docker
  fi
  if ! docker ps &>/dev/null; then
    echo_failed
    exit 1
  fi
}

function check_docker_start() {
  prepare_set_redhat_firewalld
  if ! docker ps &>/dev/null; then
    start_docker
  fi
}

function check_docker_compose() {
  local expected=${1:-} version
  if [[ -n "${expected}" ]]; then
    version=$(docker compose version --short) || return 1
    if [[ "${version#v}" != "${expected#v}" ]]; then
      log_error "Active Docker Compose version is ${version}, expected ${expected}"
      return 1
    fi
  elif ! docker compose version &>/dev/null; then
    echo_failed "$(gettext 'Docker compose is not installed')"
    exit 1
  fi
  echo_done
}

function main() {
  echo_yellow "1. $(gettext 'Install Docker')"
  check_docker_install
  check_compose_install || exit 1
  echo_yellow "\n2. $(gettext 'Configure Docker')"
  check_docker_config
  echo_yellow "\n3. $(gettext 'Start Docker')"
  check_docker_start
  check_docker_compose
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
