#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

action=${1-}
flag=0

function usage() {
    echo "Usage: "
    echo "  ./jmsctl.sh config [ARGS...]"
    echo "  -h, --help"
    echo
    echo "Args: "
    echo "  ntp              $(gettext 'Configuration ntp sync')"
    echo "  init             $(gettext 'Initialize configuration file')"
    echo "  port             $(gettext 'Configuration service port')"
    echo "  ssl              $(gettext 'Configuration web ssl')"
    echo "  env              $(gettext 'Configuration jumpserver environment')"
}

function backup_config() {
  volume_dir=$(get_config VOLUME_DIR)
  backup_dir="${volume_dir}/config_backup"
  backup_config_file="${backup_dir}/config.conf-$(date +%F_%T)"
  if [[ ! -d ${backup_dir} ]]; then
    mkdir -p "${backup_dir}"
  fi
  cp -f "${CONFIG_FILE}" "${backup_config_file}"
}

function restart_service() {
    confirm="n"
    read_from_input confirm "$(gettext 'Do you want to restart the service')?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
        jmsctl restart
    fi
}

function set_ntp() {
    command -v ntpdate >/dev/null || {
        log_error "$(gettext 'ntpdate is not installed, please install it first')"
        exit 1
    }
    ntp_server="ntp.aliyun.com"
    read_from_input ntp_server "$(gettext 'Please enter NTP SERVER')" "" "${ntp_server}"
    ntpdate -u "${ntp_server}"
}

function set_port() {
    use_xpack=$(get_config_or_env USE_XPACK)
    koko_enable=$(get_config KOKO_ENABLE)
    magnus_enable=$(get_config MAGNUS_ENABLE)
    xrdp_enable=$(get_config XRDP_ENABLE)
    razor_enable=$(get_config RAZOR_ENABLE)
    web_enable=$(get_config WEB_ENABLE)

    if [[ "${web_enable}" != "0" ]]; then
        http_port=$(get_config HTTP_PORT)
        https_port=$(get_config HTTPS_PORT)

        read_from_input http_port "$(gettext 'Please enter HTTP PORT')" "" "${http_port}"
        set_config HTTP_PORT "${http_port}"
        if [ -n "${https_port}" ]; then
            read_from_input https_port "$(gettext 'Please enter HTTPS PORT')" "" "${https_port}"
            set_config HTTPS_PORT "${https_port}"
        fi
    fi
    if [[ "${use_xpack}" == "1" ]]; then
        if [[ "${koko_enable}" != "0" ]]; then
            ssh_port=$(get_config SSH_PORT)
            read_from_input ssh_port "$(gettext 'Please enter SSH PORT')" "" "${ssh_port}"
            set_config SSH_PORT "${ssh_port}"
        fi
        if [[ "${magnus_enable}" != "0" ]]; then
            magnus_mysql_port=$(get_config MAGNUS_MYSQL_PORT)
            read_from_input magnus_mysql_port "$(gettext 'Please enter MAGNUS MYSQL PORT')" "" "${magnus_mysql_port}"
            set_config MAGNUS_MYSQL_PORT "${magnus_mysql_port}"
            magnus_mariadb_port=$(get_config MAGNUS_MARIADB_PORT)
            read_from_input magnus_mariadb_port "$(gettext 'Please enter MAGNUS MARIADB PORT')" "" "${magnus_mariadb_port}"
            set_config MAGNUS_MARIADB_PORT "${magnus_mariadb_port}"
            magnus_redis_port=$(get_config MAGNUS_REDIS_PORT)
            read_from_input magnus_redis_port "$(gettext 'Please enter MAGNUS REDIS PORT')" "" "${magnus_redis_port}"
            set_config MAGNUS_REDIS_PORT "${magnus_redis_port}"
            magnus_postgresql_port=$(get_config MAGNUS_POSTGRESQL_PORT)
            read_from_input magnus_postgresql_port "$(gettext 'Please enter MAGNUS POSTGRESQL PORT')" "" "${magnus_postgresql_port}"
            set_config MAGNUS_POSTGRESQL_PORT "${magnus_postgresql_port}"
            magnus_sqlserver_port=$(get_config MAGNUS_SQLSERVER_PORT)
            read_from_input magnus_sqlserver_port "$(gettext 'Please enter MAGNUS SQLSERVER PORT')" "" "${magnus_sqlserver_port}"
            set_config MAGNUS_SQLSERVER_PORT "${magnus_sqlserver_port}"
        fi
        if [[ "${xrdp_enable}" != "0" ]]; then
            xrdp_port=$(get_config XRDP_PORT)
            read_from_input xrdp_port "$(gettext 'Please enter XRDP PORT')" "" "${xrdp_port}"
            set_config XRDP_PORT "${xrdp_port}"
        fi
        if [[ "${razor_enable}" != "0" ]]; then
            rdp_port=$(get_config RDP_PORT)
            read_from_input rdp_port "$(gettext 'Please enter RAZOR PORT')" "" "${rdp_port}"
            set_config RDP_PORT "${rdp_port}"
        fi
        if [[ "${magnus_enable}" != "0" ]]; then
            magnus_oracle_ports=$(get_config MAGNUS_ORACLE_PORTS)
            read_from_input magnus_oracle_ports "$(gettext 'Please enter MAGNUS ORACLE PORTS')" "" "${magnus_oracle_ports}"
            set_config MAGNUS_ORACLE_PORTS "${magnus_oracle_ports}"
        fi
    fi
    flag=1
}

function set_ssl() {
    http_port=$(get_config HTTP_PORT)
    https_port=$(get_config HTTPS_PORT)
    server_name=$(get_config SERVER_NAME)
    ssl_certificate=$(get_config SSL_CERTIFICATE)
    ssl_certificate_key=$(get_config SSL_CERTIFICATE_KEY)
    ssl_certificate_file=''
    ssl_certificate_key_file=''

    read_from_input http_port "$(gettext 'Please enter HTTP PORT')" "" "${http_port}"
    read_from_input https_port "$(gettext 'Please enter HTTPS PORT')" "" "${https_port}"
    read_from_input server_name "$(gettext 'Please enter SERVER NAME')" "" "${server_name}"

    if [[ -z "${ssl_certificate}" ]]; then
        ssl_certificate="${server_name}.pem"
    fi
    if [[ -z "${ssl_certificate_key}" ]]; then
        ssl_certificate_key="${server_name}.key"
    fi

    read_from_input ssl_certificate_file "$(gettext 'Please enter SSL CERTIFICATE FILE Absolute path')" "" "${ssl_certificate_file}"
    if [[ ! -f "${ssl_certificate_file}" ]]; then
        log_error "$(gettext 'SSL CERTIFICATE FILE not exists'): ${ssl_certificate_file}"
        exit 1
    fi
    cp -f "${ssl_certificate_file}" "${CONFIG_DIR}/nginx/cert/${ssl_certificate}"
    chmod 600 "${CONFIG_DIR}/nginx/cert/${ssl_certificate}"

    read_from_input ssl_certificate_key_file "$(gettext 'Please enter SSL CERTIFICATE KEY FILE Absolute path')" "" "${ssl_certificate_key_file}"
    if [[ ! -f "${ssl_certificate_key_file}" ]]; then
        log_error "$(gettext 'SSL CERTIFICATE KEY FILE not exists'): ${ssl_certificate_key_file}"
        exit 1
    fi
    cp -f "${ssl_certificate_key_file}" "${CONFIG_DIR}/nginx/cert/${ssl_certificate_key}"
    chmod 600 "${CONFIG_DIR}/nginx/cert/${ssl_certificate_key}"

    set_config HTTP_PORT "${http_port}"
    set_config HTTPS_PORT "${https_port}"
    set_config SERVER_NAME "${server_name}"
    set_config SSL_CERTIFICATE "${ssl_certificate}"
    set_config SSL_CERTIFICATE_KEY "${ssl_certificate_key}"
    flag=1
}

function set_env() {
    while true; do
        key=''
        value=''
        read_from_input key "$(gettext 'Please enter the environment variable key')" "" "${key}"
        if [[ -z "${key}" ]]; then
            break
        fi
        default_value=$(get_config "${key}")

        if [[ -n "${default_value}" ]]; then
            value="${default_value}"
        fi
        read_from_input value "$(gettext 'Please enter the environment variable value')" "" "${value}"
        echo ""
        if [[ "${value}" != "${default_value}" ]]; then
            echo_yellow "$(gettext 'The operation changes are as follows')"
            echo "(old) ${key}: ${default_value}"
            echo "(new) ${key}: ${value}"

            confirm="n"
            read_from_input confirm "$(gettext 'Do you want to update the environment variable')?" "y/n" "${confirm}"
            if [[ "${confirm}" != "y" ]]; then
                break
            fi
            set_config "${key}" "${value}"
            flag=1
        else
            echo_yellow "$(gettext 'The environment variable has not changed')"
        fi

        echo ""
        confirm="n"
        read_from_input confirm "$(gettext 'Do you want to continue to add environment variables')?" "y/n" "${confirm}"
        if [[ "${confirm}" != "y" ]]; then
            break
        fi
        echo ""
    done
}

function main() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        log_error "$(gettext 'Configuration file not found'): ${CONFIG_FILE}"
        exit 1
    fi

    case "${action}" in
    init)
        prepare_config
        ;;
    port)
        backup_config
        set_port
        ;;
    ntp)
        set_ntp
        ;;
    ssl)
        backup_config
        set_ssl
        ;;
    env)
        backup_config
        set_env
        ;;
    -h | --help)
        usage
        ;;
    *)
        usage
        ;;
    esac
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi

if [[ "${flag}" == "1" ]]; then
    restart_service
fi