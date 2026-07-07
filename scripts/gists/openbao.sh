#!/usr/bin/env bash

function is_internal_openbao_enabled() {
  local vault_enabled vault_backend openbao_external

  vault_enabled=$(get_config_or_env VAULT_ENABLED)
  vault_backend=$(get_config_or_env VAULT_BACKEND)
  openbao_external=$(get_config_or_env OPENBAO_EXTERNAL "false")

  case "${vault_enabled}" in
    1|true|True|TRUE) ;;
    *) return 1 ;;
  esac
  [[ "${vault_backend}" == "openbao" ]] || return 1
  case "${openbao_external}" in
    1|true|True|TRUE) return 1 ;;
  esac
  return 0
}

function get_openbao_image() {
  get_config_or_env OPENBAO_IMAGE "openbao/openbao:2.6.0"
}

function should_include_openbao_image() {
  case "${INCLUDE_OPENBAO_IMAGE:-}" in
    1|true|True|TRUE) return 0 ;;
  esac
  is_internal_openbao_enabled
}

function set_openbao() {
  local vault_enabled vault_backend openbao_external vault_addr vault_token

  vault_enabled=$(get_config VAULT_ENABLED "false")
  vault_backend=$(get_config VAULT_BACKEND "openbao")
  openbao_external=$(get_config OPENBAO_EXTERNAL "false")

  set_config VAULT_ENABLED "${vault_enabled}"
  if [[ "${vault_enabled}" != "1" && "${vault_enabled}" != "true" && "${vault_enabled}" != "True" && "${vault_enabled}" != "TRUE" ]]; then
    return
  fi
  if [[ "${vault_backend}" != "openbao" ]]; then
    return
  fi

  vault_addr=$(get_config VAULT_OPENBAO_ADDR)
  vault_token=$(get_config VAULT_OPENBAO_TOKEN)

  if [[ "${openbao_external}" == "1" || "${openbao_external}" == "true" || "${openbao_external}" == "True" || "${openbao_external}" == "TRUE" ]]; then
    if [[ -z "${vault_token}" ]]; then
      log_error "$(gettext 'VAULT_OPENBAO_TOKEN is required when using external OpenBao')"
      return 1
    fi
    if [[ -z "${vault_addr}" || "${vault_addr}" == "http://openbao:8200" || "${vault_addr}" == "https://openbao:8200" ]]; then
      log_error "$(gettext 'Set VAULT_OPENBAO_ADDR to the external OpenBao address')"
      return 1
    fi
  else
    if [[ -z "${vault_addr}" ]]; then
      vault_addr="http://openbao:8200"
    fi
    if [[ -z "${vault_token}" ]]; then
      vault_token=$(random_str 48)
      set_config VAULT_OPENBAO_TOKEN "${vault_token}"
    fi
  fi

  set_config VAULT_BACKEND openbao
  set_config VAULT_OPENBAO_ADDR "${vault_addr}"
  set_config VAULT_OPENBAO_MOUNT_POINT "$(get_config VAULT_OPENBAO_MOUNT_POINT pam)"
  set_config VAULT_OPENBAO_TIMEOUT "$(get_config VAULT_OPENBAO_TIMEOUT 10)"
  set_config OPENBAO_EXTERNAL "${openbao_external}"

  if [[ "${openbao_external}" == "1" || "${openbao_external}" == "true" || "${openbao_external}" == "True" || "${openbao_external}" == "TRUE" ]]; then
    return 0
  fi

  set_config OPENBAO_RAFT_NODE_ID "$(get_config OPENBAO_RAFT_NODE_ID openbao)"
  set_config OPENBAO_RAFT_API_ADDR "$(get_config OPENBAO_RAFT_API_ADDR http://openbao:8200)"
  set_config OPENBAO_RAFT_CLUSTER_ADDR "$(get_config OPENBAO_RAFT_CLUSTER_ADDR http://openbao:8201)"
  set_config OPENBAO_RAFT_BOOTSTRAP "$(get_config OPENBAO_RAFT_BOOTSTRAP true)"
  set_config OPENBAO_UNSEAL_KEY_SHARES "$(get_config OPENBAO_UNSEAL_KEY_SHARES 5)"
  set_config OPENBAO_UNSEAL_KEY_THRESHOLD "$(get_config OPENBAO_UNSEAL_KEY_THRESHOLD 3)"
  set_openbao_bootstrap_script
  set_openbao_server_config
}

function set_openbao_bootstrap_script() {
  local source_file target_file

  source_file="${PROJECT_DIR}/config_init/openbao/bootstrap.sh"
  target_file="${CONFIG_DIR}/openbao/bootstrap.sh"
  mkdir -p "${CONFIG_DIR}/openbao"
  cp -f "${source_file}" "${target_file}"
  chmod 600 "${target_file}" 2>/dev/null || true
}

function set_openbao_server_config() {
  local config_file data_path node_id api_addr cluster_addr retry_join addr

  config_file="${CONFIG_DIR}/openbao/server.hcl"
  data_path="/openbao/file"
  node_id=$(get_config OPENBAO_RAFT_NODE_ID openbao)
  api_addr=$(get_config OPENBAO_RAFT_API_ADDR http://openbao:8200)
  cluster_addr=$(get_config OPENBAO_RAFT_CLUSTER_ADDR http://openbao:8201)
  retry_join=$(get_config OPENBAO_RAFT_RETRY_JOIN)

  mkdir -p "${CONFIG_DIR}/openbao"

  cat >"${config_file}" <<EOF
ui = true
disable_mlock = true

storage "raft" {
  path = "${data_path}"
  node_id = "${node_id}"
EOF

  for addr in ${retry_join//,/ }; do
    [[ -z "${addr}" ]] && continue
    cat >>"${config_file}" <<EOF

  retry_join {
    leader_api_addr = "${addr}"
  }
EOF
  done

  cat >>"${config_file}" <<EOF
}

listener "tcp" {
  address = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable = true
}

api_addr = "${api_addr}"
cluster_addr = "${cluster_addr}"
EOF

  # This file contains no credentials and must be readable by the non-root
  # OpenBao process inside the container.
  chmod 644 "${config_file}" 2>/dev/null || true
}
