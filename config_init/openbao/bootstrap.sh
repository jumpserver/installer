#!/bin/sh
set -eu

export BAO_ADDR="${BAO_ADDR:-http://openbao:8200}"

VAULT_ENABLED="${VAULT_ENABLED:-false}"
VAULT_BACKEND="${VAULT_BACKEND:-openbao}"
KV_MOUNT_POINT="${VAULT_OPENBAO_MOUNT_POINT:-pam}"
KV_SERVICE_TOKEN="${VAULT_OPENBAO_TOKEN:-}"
SSH_CA_ENABLED="${SSH_CA_ENABLED:-false}"
SSH_CA_MOUNT_POINT="${SSH_CA_OPENBAO_MOUNT_POINT:-ssh-client-signer}"
SSH_CA_ROLE="${SSH_CA_OPENBAO_ROLE:-jumpserver}"
SSH_CA_TTL="${SSH_CA_OPENBAO_TTL:-300}"
SSH_CA_SERVICE_TOKEN="${SSH_CA_OPENBAO_TOKEN:-}"
RAFT_BOOTSTRAP="${OPENBAO_RAFT_BOOTSTRAP:-true}"
UNSEAL_KEY_SHARES="${OPENBAO_UNSEAL_KEY_SHARES:-5}"
UNSEAL_KEY_THRESHOLD="${OPENBAO_UNSEAL_KEY_THRESHOLD:-3}"
INIT_FILE="/openbao/bootstrap/init.json"
KV_POLICY_FILE="/tmp/jumpserver-kv-policy.hcl"
KV_SERVICE_TOKEN_FILE="/openbao/bootstrap/jumpserver-token.json"
SSH_CA_POLICY_FILE="/tmp/jumpserver-ssh-ca-policy.hcl"
SSH_CA_SERVICE_TOKEN_FILE="/openbao/bootstrap/jumpserver-ssh-ca-token.json"

wait_openbao() {
  i=0
  while [ "$i" -lt 60 ]; do
    if bao status >/tmp/openbao-status 2>&1; then
      return 0
    fi
    if grep -q "Initialized" /tmp/openbao-status 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  cat /tmp/openbao-status 2>/dev/null || true
  echo "OpenBao is not reachable"
  exit 1
}

json_value() {
  key="$1"
  tr -d '\n ' <"${INIT_FILE}" | sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p"
}

json_array_first() {
  key="$1"
  tr -d '\n ' <"${INIT_FILE}" | sed -n "s/.*\"${key}\":\\[\"\\([^\"]*\\)\".*/\\1/p"
}

json_array_values() {
  key="$1"
  tr -d '\n ' <"${INIT_FILE}" | sed -n "s/.*\"${key}\":\\[\\([^]]*\\)\\].*/\\1/p" | tr ',' '\n' | sed 's/^"//;s/"$//'
  printf '\n'
}

is_true() {
  case "$1" in
    1|true|True|TRUE|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

is_initialized() {
  bao status 2>/dev/null | grep -q "Initialized[[:space:]]*true"
}

is_uninitialized() {
  bao status 2>/dev/null | grep -q "Initialized[[:space:]]*false"
}

is_sealed() {
  bao status 2>/dev/null | grep -q "Sealed[[:space:]]*true"
}

wait_unsealed() {
  i=0
  while [ "$i" -lt 30 ]; do
    if ! is_sealed; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

unseal_openbao() {
  if ! is_sealed; then
    return 0
  fi

  json_array_values unseal_keys_b64 | while IFS= read -r key; do
    [ -z "${key}" ] && continue
    if ! is_sealed; then
      break
    fi
    bao operator unseal "${key}" >/dev/null
  done

  if ! wait_unsealed; then
    echo "OpenBao is still sealed after applying unseal keys from ${INIT_FILE}."
    exit 1
  fi
}

ensure_service_token() {
  service_token="$1"
  policy_name="$2"
  token_file="$3"

  [ -n "${service_token}" ] || return 0
  if bao token lookup "${service_token}" >/dev/null 2>&1; then
    return 0
  fi

  bao token create \
    -id="${service_token}" \
    -policy="${policy_name}" \
    -orphan \
    -no-default-policy \
    -format=json >"${token_file}"
  chmod 600 "${token_file}" 2>/dev/null || true
}

configure_kv_backend() {
  if ! bao secrets list -format=json | grep -q "\"${KV_MOUNT_POINT}/\""; then
    bao secrets enable -path="${KV_MOUNT_POINT}" -version=2 kv
  fi

  bao write "${KV_MOUNT_POINT}/config" max_versions=20 >/dev/null

  cat >"${KV_POLICY_FILE}" <<POLICY
path "${KV_MOUNT_POINT}/data/*" {
  capabilities = ["create", "read", "update", "patch"]
}

path "${KV_MOUNT_POINT}/metadata/*" {
  capabilities = ["create", "update", "delete"]
}
POLICY

  bao policy write jumpserver "${KV_POLICY_FILE}" >/dev/null
  ensure_service_token "${KV_SERVICE_TOKEN}" jumpserver "${KV_SERVICE_TOKEN_FILE}"
}

configure_ssh_ca() {
  case "${SSH_CA_TTL}" in
    ''|*[!0-9]*)
      echo "SSH_CA_OPENBAO_TTL must be an integer between 30 and 3600 seconds."
      exit 1
      ;;
  esac
  if [ "${SSH_CA_TTL}" -lt 30 ] || [ "${SSH_CA_TTL}" -gt 3600 ]; then
    echo "SSH_CA_OPENBAO_TTL must be between 30 and 3600 seconds."
    exit 1
  fi

  if ! bao secrets list -format=json | grep -q "\"${SSH_CA_MOUNT_POINT}/\""; then
    bao secrets enable -path="${SSH_CA_MOUNT_POINT}" ssh
  fi

  if ! bao read -field=public_key "${SSH_CA_MOUNT_POINT}/config/ca" >/dev/null 2>&1; then
    bao write "${SSH_CA_MOUNT_POINT}/config/ca" generate_signing_key=true >/dev/null
  fi

  bao write "${SSH_CA_MOUNT_POINT}/roles/${SSH_CA_ROLE}" \
    key_type=ca \
    algorithm_signer=default \
    allow_user_certificates=true \
    allowed_users="*" \
    allow_user_key_ids=true \
    allowed_extensions="permit-pty,permit-port-forwarding" \
    allowed_critical_options="source-address" \
    ttl="${SSH_CA_TTL}s" \
    max_ttl=1h >/dev/null

  cat >"${SSH_CA_POLICY_FILE}" <<POLICY
path "${SSH_CA_MOUNT_POINT}/sign/${SSH_CA_ROLE}" {
  capabilities = ["create", "update"]
}

path "${SSH_CA_MOUNT_POINT}/public_key" {
  capabilities = ["read"]
}
POLICY

  bao policy write jumpserver-ssh-ca "${SSH_CA_POLICY_FILE}" >/dev/null
  ensure_service_token \
    "${SSH_CA_SERVICE_TOKEN}" \
    jumpserver-ssh-ca \
    "${SSH_CA_SERVICE_TOKEN_FILE}"
}

wait_openbao

if is_uninitialized; then
  if is_true "${RAFT_BOOTSTRAP}"; then
    bao operator init -key-shares="${UNSEAL_KEY_SHARES}" -key-threshold="${UNSEAL_KEY_THRESHOLD}" -format=json >"${INIT_FILE}"
    chmod 600 "${INIT_FILE}" 2>/dev/null || true
  else
    i=0
    while [ "$i" -lt 60 ]; do
      is_initialized && break
      i=$((i + 1))
      sleep 1
    done
    if is_uninitialized; then
      echo "OpenBao is not initialized. Set OPENBAO_RAFT_BOOTSTRAP=true on the first Raft node, or wait for retry_join to finish."
      exit 1
    fi
  fi
fi

if [ ! -f "${INIT_FILE}" ]; then
  echo "OpenBao is initialized, but ${INIT_FILE} is missing; cannot unseal automatically."
  echo "On an additional Raft node, copy init.json from the bootstrap node to this node before startup."
  exit 1
fi

ROOT_TOKEN="$(json_value root_token)"

if [ -z "${ROOT_TOKEN}" ] || [ -z "$(json_array_first unseal_keys_b64)" ]; then
  echo "Invalid OpenBao initialization file: ${INIT_FILE}"
  exit 1
fi

unseal_openbao

export BAO_TOKEN="${ROOT_TOKEN}"

if is_true "${VAULT_ENABLED}" && [ "${VAULT_BACKEND}" = "openbao" ]; then
  configure_kv_backend
fi

if is_true "${SSH_CA_ENABLED}"; then
  configure_ssh_ca
fi
