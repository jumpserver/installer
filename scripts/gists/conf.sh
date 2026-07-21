
function has_config() {
  key=$1
  if grep "^[ \t]*${key}=" "${CONFIG_FILE}" &>/dev/null; then
    echo "1"
  else
    echo "0"
  fi
}

function get_config() {
  key=$1
  default=${2-''}

  if [[ -f "${CONFIG_FILE}" ]]; then
    value=$(grep "^${key}=" "${CONFIG_FILE}" | awk -F= '{ print $2 }' | awk -F' ' '{ print $1 }' | tail -1)
  fi

  if [[ -z "$value" ]];then
    value="$default"
  fi
  echo "${value}"
}

function get_config_or_env() {
  key=$1
  value=''
  default=${2-''}

  value="${!key}"
  if [[ -z "$value" && -f "${CONFIG_FILE}" ]];then
    value=$(get_config "$key")
  fi

  if [[ -z "$value" ]];then
    value="$default"
  fi
  echo "${value}"
}

CONFIG_SAFE_EXCLUDES="DB_HOST DB_PORT DB_PASSWORD"

function gen_safe_config() {
  local base_config_file=${CONFIG_FILE}
  local output_file=${CONFIG_SAFE_FILE}
  local tmp_file="${output_file}.tmp.$$"
  local excluded

  mkdir -p "${CONFIG_DIR}"
  if [[ -f "${base_config_file}" ]]; then
    cp "${base_config_file}" "${tmp_file}"
    for excluded in ${CONFIG_SAFE_EXCLUDES}; do
      sed_in_place "/^[[:space:]]*${excluded}=/d" "${tmp_file}"
    done
  else
    : >"${tmp_file}"
  fi

  if [[ -f "${output_file}" ]] && cmp -s "${tmp_file}" "${output_file}"; then
    rm -f "${tmp_file}"
    echo "${output_file}"
    return
  fi

  mv -f "${tmp_file}" "${output_file}"
  chmod 600 "${output_file}" 2>/dev/null || true
  echo "${output_file}"
}

function sed_in_place() {
  # macOS requires a backup extension for sed -i, even if empty
  if [[ "${OS}" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

function set_config() {
  key=$1
  value=$2

  has=$(has_config "${key}")
  if [[ ${has} == "0" ]]; then
    echo "${key}=${value}" >>"${CONFIG_FILE}"
    return
  fi

  origin_value=$(get_config "${key}")
  if [[ "${value}" == "${origin_value}" ]]; then
    return
  fi

  sed_in_place "s,^[ \t]*${key}=.*$,${key}=${value},g" "${CONFIG_FILE}"
}

function remove_config() {
  key=$1

  has=$(has_config "${key}")
  if [[ ${has} == "1" ]]; then
    sed_in_place "/^[ \t]*${key}=.*$/d" "${CONFIG_FILE}"
  fi
}

function disable_config() {
  key=$1

  has=$(has_config "${key}")
  if [[ ${has} == "1" ]]; then
    sed_in_place "s,^[ \t]*${key}=.*$,# ${key}=,g" "${CONFIG_FILE}"
  fi
}


function get_config_enabled() {
  key=$1
  value=$(get_config "${key}")
  if [[ "${value}" == "0" || "${value}" == "false" || "${value}" == "False" ]]; then
    return 0
  else
    return 1
  fi
}


function prepare_config() {
  cd "${PROJECT_DIR}" || exit 1
  if check_root; then
    echo -e "#!/usr/bin/env bash\n#" > /usr/bin/jmsctl
    echo -e "cd ${PROJECT_DIR}" >> /usr/bin/jmsctl
    echo -e './jmsctl.sh $@' >> /usr/bin/jmsctl
    chmod 755 /usr/bin/jmsctl
  fi

  echo_yellow "1. $(gettext 'Check Configuration File')"
  echo "$(gettext 'Path to Configuration file'): ${CONFIG_DIR}"
  if [[ ! -d ${CONFIG_DIR} ]]; then
    mkdir -p "${CONFIG_DIR}"
    cp config-example.txt "${CONFIG_FILE}"
  fi
  if [[ ! -f ${CONFIG_FILE} ]]; then
    cp config-example.txt "${CONFIG_FILE}"
  else
    echo_check "${CONFIG_FILE}"
  fi
  if [[ ! -f ".env" ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi
  if [[ ! -f "./compose/.env" ]]; then
    ln -s "${CONFIG_FILE}" ./compose/.env
  fi

  # shellcheck disable=SC2045
  for d in $(ls "${PROJECT_DIR}/config_init"); do
    if [[ -d "${PROJECT_DIR}/config_init/${d}" ]]; then
      for f in $(ls "${PROJECT_DIR}/config_init/${d}"); do
        if [[ -f "${PROJECT_DIR}/config_init/${d}/${f}" ]]; then
          if [[ ! -f "${CONFIG_DIR}/${d}/${f}" ]]; then
            \cp -rf "${PROJECT_DIR}/config_init/${d}" "${CONFIG_DIR}"
          else
            echo_check "${CONFIG_DIR}/${d}/${f}"
          fi
        fi
      done
    fi
  done

  nginx_cert_dir="${CONFIG_DIR}/nginx/cert"
  if [[ ! -d ${nginx_cert_dir} ]]; then
    mkdir -p "${nginx_cert_dir}"
    \cp -rf "${PROJECT_DIR}/config_init/nginx/cert" "${CONFIG_DIR}/nginx"
  fi

  # shellcheck disable=SC2045
  for f in $(ls "${PROJECT_DIR}/config_init/nginx/cert"); do
    if [[ -f "${PROJECT_DIR}/config_init/nginx/cert/${f}" ]]; then
      if [[ ! -f "${nginx_cert_dir}/${f}" ]]; then
        \cp -f "${PROJECT_DIR}/config_init/nginx/cert/${f}" "${nginx_cert_dir}"
      else
        echo_check "${nginx_cert_dir}/${f} "
      fi
    fi
  done
  chmod 700 "${CONFIG_DIR}/../"
  find "${CONFIG_DIR}" -type d -exec chmod 700 {} \;
  find "${CONFIG_DIR}" -type f -exec chmod 600 {} \;
  chmod 644 "${CONFIG_DIR}/redis/redis.conf"

  if [[ "$(uname -m)" == "aarch64" ]]; then
    sed_in_place "s/# ignore-warnings ARM64-COW-BUG/ignore-warnings ARM64-COW-BUG/g" "${CONFIG_DIR}/redis/redis.conf"
  fi

  gen_safe_config >/dev/null
}

function ensure_core_data_symlink() {
  local target_dir link_path="/opt/jumpserver/data" backup_base="/opt/jumpserver/data_bak" backup_path
  target_dir="$(get_config VOLUME_DIR)/core/data"

  mkdir -p "${target_dir}" "/opt/jumpserver" || return 1

  if [[ -L "${link_path}" ]] && [[ "$(readlink -f "${link_path}")" == "$(readlink -f "${target_dir}")" ]]; then
    echo_check "${link_path} -> ${target_dir}"
    return 0
  fi

  if [[ -e "${link_path}" ]]; then
    backup_path="${backup_base}"
    if [[ -e "${backup_path}" ]]; then
      backup_path="${backup_base}_$(date +%Y%m%d%H%M%S)"
    fi
    log_warn "${link_path} exists, backup to ${backup_path}"
    mv "${link_path}" "${backup_path}" || return 1
  fi

  ln -s "${target_dir}" "${link_path}" || return 1
  echo_check "${link_path} -> ${target_dir}"
}
