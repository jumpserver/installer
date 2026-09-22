#!/usr/bin/env bash

function openbao_value_is_true() {
  case "$1" in
    1|true|True|TRUE|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

function is_vault_openbao_enabled() {
  local vault_enabled vault_backend

  vault_enabled=$(get_config_or_env VAULT_ENABLED)
  vault_backend=$(get_config_or_env VAULT_BACKEND)

  openbao_value_is_true "${vault_enabled}" || return 1
  [[ "${vault_backend}" == "openbao" ]] || return 1
  return 0
}

function is_ssh_ca_enabled() {
  openbao_value_is_true "$(get_config_or_env SSH_CA_ENABLED "false")"
}

function is_internal_openbao_enabled() {
  local openbao_external

  openbao_external=$(get_config_or_env OPENBAO_EXTERNAL "false")
  openbao_value_is_true "${openbao_external}" && return 1

  is_vault_openbao_enabled && return 0
  is_ssh_ca_enabled && return 0
  return 1
}

function get_openbao_image() {
  echo "openbao/openbao:2.6.0"
}

function should_include_openbao_image() {
  case "${INCLUDE_OPENBAO_IMAGE:-}" in
    1|true|True|TRUE) return 0 ;;
  esac
  is_internal_openbao_enabled
}

function set_openbao() {
  local vault_enabled vault_backend ssh_ca_enabled openbao_external
  local vault_addr ssh_ca_addr vault_token ssh_ca_token
  local api_addr cluster_addr
  local vault_openbao_required="false" ssh_ca_required="false"
  local internal_ca_file="/opt/jumpserver/data/certs/openbao/ca.crt"

  vault_enabled=$(get_config VAULT_ENABLED "false")
  vault_backend=$(get_config VAULT_BACKEND "openbao")
  ssh_ca_enabled=$(get_config SSH_CA_ENABLED "false")
  openbao_external=$(get_config OPENBAO_EXTERNAL "false")

  set_config VAULT_ENABLED "${vault_enabled}"
  set_config SSH_CA_ENABLED "${ssh_ca_enabled}"
  set_config OPENBAO_EXTERNAL "${openbao_external}"

  if openbao_value_is_true "${vault_enabled}" && [[ "${vault_backend}" == "openbao" ]]; then
    vault_openbao_required="true"
  fi
  if openbao_value_is_true "${ssh_ca_enabled}"; then
    ssh_ca_required="true"
  fi

  if [[ "${vault_openbao_required}" != "true" && "${ssh_ca_required}" != "true" ]]; then
    return 0
  fi

  vault_addr=$(get_config VAULT_OPENBAO_ADDR)
  ssh_ca_addr=$(get_config SSH_CA_OPENBAO_ADDR)
  vault_token=$(get_config VAULT_OPENBAO_TOKEN)
  ssh_ca_token=$(get_config SSH_CA_OPENBAO_TOKEN)

  if [[ -z "${vault_addr}" ]]; then
    vault_addr="https://openbao:8200"
  fi
  # Preserve upgrades from versions where SSH CA reused VAULT_OPENBAO_ADDR.
  if [[ -z "${ssh_ca_addr}" ]]; then
    ssh_ca_addr="${vault_addr}"
  fi

  set_config VAULT_OPENBAO_ADDR "${vault_addr}"
  set_config SSH_CA_OPENBAO_ADDR "${ssh_ca_addr}"
  set_config SSH_CA_OPENBAO_MOUNT_POINT "$(get_config SSH_CA_OPENBAO_MOUNT_POINT ssh-client-signer)"
  set_config SSH_CA_OPENBAO_ROLE "$(get_config SSH_CA_OPENBAO_ROLE jumpserver)"
  set_config SSH_CA_OPENBAO_TTL "$(get_config SSH_CA_OPENBAO_TTL 300)"
  set_config SSH_CA_OPENBAO_TIMEOUT "$(get_config SSH_CA_OPENBAO_TIMEOUT 10)"
  set_config SSH_CA_OPENBAO_VERIFY_TLS "$(get_config SSH_CA_OPENBAO_VERIFY_TLS true)"
  set_config SSH_CA_OPENBAO_CACERT_FILE "$(get_config SSH_CA_OPENBAO_CACERT_FILE)"
  set_config SSH_CA_OPENBAO_SOURCE_ADDRESS "$(get_config SSH_CA_OPENBAO_SOURCE_ADDRESS)"

  if openbao_value_is_true "${openbao_external}"; then
    if [[ "${vault_openbao_required}" == "true" ]] && \
        { [[ -z "${vault_addr}" ]] || [[ "${vault_addr}" == "http://openbao:8200" ]] || [[ "${vault_addr}" == "https://openbao:8200" ]]; }; then
      log_error "$(gettext 'Set VAULT_OPENBAO_ADDR to the external OpenBao address')"
      return 1
    fi
    if [[ "${ssh_ca_required}" == "true" ]] && \
        { [[ -z "${ssh_ca_addr}" ]] || [[ "${ssh_ca_addr}" == "http://openbao:8200" ]] || [[ "${ssh_ca_addr}" == "https://openbao:8200" ]]; }; then
      log_error "$(gettext 'Set SSH_CA_OPENBAO_ADDR to the external OpenBao address')"
      return 1
    fi
    if [[ "${vault_openbao_required}" == "true" && -z "${vault_token}" ]]; then
      log_error "$(gettext 'VAULT_OPENBAO_TOKEN is required when using external OpenBao')"
      return 1
    fi
    if [[ "${ssh_ca_required}" == "true" && -z "${ssh_ca_token}" ]]; then
      log_error "$(gettext 'SSH_CA_OPENBAO_TOKEN is required when using external OpenBao')"
      return 1
    fi
  else
    if [[ "${vault_openbao_required}" == "true" && -z "${vault_token}" ]]; then
      vault_token=$(random_secret 24) || return 1
      set_config VAULT_OPENBAO_TOKEN "${vault_token}"
    fi
    if [[ "${ssh_ca_required}" == "true" && -z "${ssh_ca_token}" ]]; then
      ssh_ca_token=$(random_secret 24) || return 1
      set_config SSH_CA_OPENBAO_TOKEN "${ssh_ca_token}"
    fi
    if [[ "${vault_openbao_required}" == "true" && "${ssh_ca_required}" == "true" && "${vault_token}" == "${ssh_ca_token}" ]]; then
      ssh_ca_token=$(random_secret 24) || return 1
      set_config SSH_CA_OPENBAO_TOKEN "${ssh_ca_token}"
    fi
  fi

  if [[ "${vault_openbao_required}" == "true" ]]; then
    set_config VAULT_BACKEND openbao
    set_config VAULT_OPENBAO_MOUNT_POINT "$(get_config VAULT_OPENBAO_MOUNT_POINT pam)"
    set_config VAULT_OPENBAO_TIMEOUT "$(get_config VAULT_OPENBAO_TIMEOUT 10)"
    set_config VAULT_OPENBAO_VERIFY_TLS "$(get_config VAULT_OPENBAO_VERIFY_TLS true)"
    set_config VAULT_OPENBAO_CACERT_FILE "$(get_config VAULT_OPENBAO_CACERT_FILE)"
  fi

  if openbao_value_is_true "${openbao_external}"; then
    return 0
  fi

  vault_addr="https://openbao:8200"
  ssh_ca_addr="https://openbao:8200"
  set_config VAULT_OPENBAO_ADDR "${vault_addr}"
  set_config SSH_CA_OPENBAO_ADDR "${ssh_ca_addr}"
  if [[ "${vault_openbao_required}" == "true" ]]; then
    set_config VAULT_OPENBAO_VERIFY_TLS true
    set_config VAULT_OPENBAO_CACERT_FILE "${internal_ca_file}"
  fi
  if [[ "${ssh_ca_required}" == "true" ]]; then
    set_config SSH_CA_OPENBAO_VERIFY_TLS true
    set_config SSH_CA_OPENBAO_CACERT_FILE "${internal_ca_file}"
  fi

  set_config OPENBAO_RAFT_NODE_ID "$(get_config OPENBAO_RAFT_NODE_ID openbao)"
  api_addr=$(get_config OPENBAO_RAFT_API_ADDR https://openbao:8200)
  cluster_addr=$(get_config OPENBAO_RAFT_CLUSTER_ADDR https://openbao:8201)
  [[ "${api_addr}" == "http://openbao:8200" ]] && api_addr="https://openbao:8200"
  [[ "${cluster_addr}" == "http://openbao:8201" ]] && cluster_addr="https://openbao:8201"
  set_config OPENBAO_RAFT_API_ADDR "${api_addr}"
  set_config OPENBAO_RAFT_CLUSTER_ADDR "${cluster_addr}"
  set_config OPENBAO_RAFT_BOOTSTRAP "$(get_config OPENBAO_RAFT_BOOTSTRAP true)"
  set_config OPENBAO_UNSEAL_KEY_SHARES "$(get_config OPENBAO_UNSEAL_KEY_SHARES 5)"
  set_config OPENBAO_UNSEAL_KEY_THRESHOLD "$(get_config OPENBAO_UNSEAL_KEY_THRESHOLD 3)"
  set_openbao_tls || return 1
  set_openbao_bootstrap_script
  set_openbao_server_config
}

function set_openbao_tls() {
  local tls_dir ca_key ca_cert server_key server_csr server_cert server_ext
  local openssl_output

  tls_dir="${CONFIG_DIR}/openbao/tls"
  ca_key="${tls_dir}/ca.key"
  ca_cert="${tls_dir}/ca.crt"
  server_key="${tls_dir}/server.key"
  server_csr="${tls_dir}/server.csr"
  server_cert="${tls_dir}/server.crt"
  server_ext="${tls_dir}/server.ext"

  mkdir -p "${tls_dir}" || return 1

  if [[ -f "${ca_cert}" && -f "${server_key}" && -f "${server_cert}" ]]; then
    chmod 600 "${server_key}" 2>/dev/null || true
    chmod 644 "${ca_cert}" "${server_cert}" 2>/dev/null || true
    chown 100:1000 "${server_key}" 2>/dev/null || true
    return 0
  fi

  if [[ -e "${ca_cert}" || -e "${server_key}" || -e "${server_cert}" ]]; then
    log_error "$(gettext 'OpenBao TLS certificate files are incomplete')"
    return 1
  fi

  if ! openbao_value_is_true "$(get_config OPENBAO_RAFT_BOOTSTRAP true)"; then
    log_error "$(gettext 'OpenBao TLS certificate files are incomplete')"
    return 1
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    log_error "$(gettext 'OpenSSL is required to generate the OpenBao certificate')"
    return 1
  fi

  if ! openssl_output=$(openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
      -keyout "${ca_key}" -out "${ca_cert}" \
      -subj "/CN=JumpServer OpenBao CA" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" 2>&1); then
    log_error "${openssl_output}"
    return 1
  fi

  if ! openssl_output=$(openssl req -nodes -newkey rsa:2048 -sha256 \
      -keyout "${server_key}" -out "${server_csr}" \
      -subj "/CN=openbao" 2>&1); then
    log_error "${openssl_output}"
    return 1
  fi

  cat >"${server_ext}" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:openbao,DNS:localhost,IP:127.0.0.1
EOF

  if ! openssl_output=$(openssl x509 -req -sha256 -days 3650 \
      -in "${server_csr}" -CA "${ca_cert}" -CAkey "${ca_key}" -CAcreateserial \
      -out "${server_cert}" -extfile "${server_ext}" 2>&1); then
    log_error "${openssl_output}"
    return 1
  fi

  rm -f "${ca_key}" "${server_csr}" "${server_ext}" "${tls_dir}/ca.srl"
  chmod 600 "${server_key}" 2>/dev/null || true
  chmod 644 "${ca_cert}" "${server_cert}" 2>/dev/null || true
  chown 100:1000 "${server_key}" 2>/dev/null || true
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
  api_addr=$(get_config OPENBAO_RAFT_API_ADDR https://openbao:8200)
  cluster_addr=$(get_config OPENBAO_RAFT_CLUSTER_ADDR https://openbao:8201)
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
    [[ "${addr}" == http://openbao* ]] && addr="https://${addr#http://}"
    cat >>"${config_file}" <<EOF

  retry_join {
    leader_api_addr = "${addr}"
    leader_ca_cert_file = "/openbao/tls/ca.crt"
    leader_tls_servername = "openbao"
  }
EOF
  done

  cat >>"${config_file}" <<EOF
}

listener "tcp" {
  address = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable = false
  tls_disable_client_certs = true
  tls_cert_file = "/openbao/tls/server.crt"
  tls_key_file = "/openbao/tls/server.key"
}

api_addr = "${api_addr}"
cluster_addr = "${cluster_addr}"
EOF

  # This file contains no credentials and must be readable by the non-root
  # OpenBao process inside the container.
  chmod 644 "${config_file}" 2>/dev/null || true
}
