BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

function check_root() {
  [[ "$(id -u)" == 0 ]]
}


function random_str() {
  len=$1
  if [[ -z ${len} ]]; then
    len=24
  fi
  uuid=""
  if check_root && command -v dmidecode &>/dev/null; then
    if [[ ${len} -gt 24 ]]; then
      uuid=$(dmidecode -s system-uuid | sha256sum | awk '{print $1}' | head -c ${len})
    fi
  fi
  if [[ "${#uuid}" == "${len}" ]]; then
    echo "${uuid}"
  else
    head -c200 < /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c ${len}; echo
  fi
}


function read_from_input() {
  var=$1
  msg=$2
  choices=$3
  default=$4

  if [[ -z "${choices}" && -n "${default}" ]]; then
    msg="${msg} [default: ${default}] "
  elif [[ "${choices}" == "y/n" ]]; then
    if [[ "${default}" == "y" ]]; then
      msg="${msg} [Y/n]"
    else
      msg="${msg} [y/N]"
    fi
  elif [[ -n "${choices}" && -n "${default}" ]]; then
    msg="${msg} [${choices}] (default: ${default})"
  else
    msg="${msg} [${choices}]"
  fi

  echo -n "${msg}: "
  if [[ "${AUTO_INSTALL}" == "1" ]]; then
    echo "${default}"
    export "${var}"="${default}"
    return
  fi

  read -r input
  if [[ -n "${input}" && "${choices}" == "y/n" ]]; then
    input=$(echo "${input}" | tr '[:upper:]' '[:lower:]')
  fi
  if [[ -z "${input}" && -n "${default}" ]]; then
    export "${var}"="${default}"
  else
    export "${var}"="${input}"
  fi
}

function get_file_md5() {
  file_path=$1
  if [[ -f "${file_path}" ]]; then
    if [[ "${OS}" == "Darwin" ]]; then
      md5 "${file_path}" | awk -F= '{ print $2 }'
    else
      md5sum "${file_path}" | awk '{ print $1 }'
    fi
  fi
}

function check_md5() {
  file=$1
  md5_should=$2

  md5=$(get_file_md5 "${file}")
  if [[ "${md5}" == "${md5_should}" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function echo_red() {
  echo -e "\033[1;31m$1\033[0m"
}

function echo_green() {
  echo -e "\033[1;32m$1\033[0m"
}

function echo_yellow() {
  echo -e "\033[1;33m$1\033[0m"
}

function echo_done() {
  sleep 0.5
  echo "$(gettext 'complete')"
}

function echo_check() {
  echo -e "$1 \t [\033[32m √ \033[0m]"
}

function echo_warn() {
  echo -e "[\033[33m WARNING \033[0m] $1"
}

function echo_failed() {
  msg="$(gettext 'fail')"
  reason=$1
  if [[ -n "${reason}" ]]; then
    msg="${msg}: ${reason}"
  fi
  echo_red "${msg}"
}

function log_success() {
  echo_green "[SUCCESS] $1"
}

function log_warn() {
  echo_yellow "[WARN] $1"
}

function log_error() {
  echo_red "[ERROR] $1"
}


function echo_logo() {
  cat "${BASE_DIR}/logo.txt"

  echo -e "\t\t\t\t\t\t\t\t   Version: \033[33m $VERSION \033[0m \n"
}


function prepare_check_required_pkg() {
  if [[ -n "$UNCHECK_DEPENDENCIES" ]]; then
    return 0
  fi
  for i in curl wget tar iptables gettext; do
    command -v $i &>/dev/null || {
        echo_red "$i: $(gettext 'command not found, Please install it first') $i"
        flag=1
    }
  done
  if [[ -n "$flag" ]]; then
    unset flag
    echo
    exit 1
  fi
}

function prepare_set_redhat_firewalld() {
  if command -v firewall-cmd&>/dev/null; then
    if firewall-cmd --state &>/dev/null; then
      docker_subnet=$(get_config DOCKER_SUBNET)
      if ! firewall-cmd --list-rich-rule | grep "${docker_subnet}"&>/dev/null; then
        firewall-cmd --zone=public --add-rich-rule="rule family=ipv4 source address=${docker_subnet} accept" >/dev/null
        firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=${docker_subnet} accept" >/dev/null
      fi
    fi
  fi
}

function get_host_ip() {
  local default_ip="127.0.0.1"
  host=$(command -v hostname &>/dev/null && hostname -I | cut -d ' ' -f1)
  if [ ! "${host}" ]; then
      host=$(command -v ip &>/dev/null && ip addr | grep 'inet ' | grep -Ev '(127.0.0.1|inet6|docker)' | awk '{print $2}' | head -n 1 | cut -d / -f1)
  fi
  if [[ ${host} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "${host}"
  else
      echo "${default_ip}"
  fi
}
