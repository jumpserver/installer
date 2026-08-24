#!/bin/sh
set -eu

export BAO_ADDR="${BAO_ADDR:-http://openbao:8200}"

MOUNT_POINT="${VAULT_OPENBAO_MOUNT_POINT:-pam}"
SERVICE_TOKEN="${VAULT_OPENBAO_TOKEN:-}"
RAFT_BOOTSTRAP="${OPENBAO_RAFT_BOOTSTRAP:-true}"
UNSEAL_KEY_SHARES="${OPENBAO_UNSEAL_KEY_SHARES:-5}"
UNSEAL_KEY_THRESHOLD="${OPENBAO_UNSEAL_KEY_THRESHOLD:-3}"
INIT_FILE="/openbao/bootstrap/init.json"
POLICY_FILE="/tmp/jumpserver-policy.hcl"
SERVICE_TOKEN_FILE="/openbao/bootstrap/jumpserver-token.json"

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

if ! bao secrets list -format=json | grep -q "\"${MOUNT_POINT}/\""; then
  bao secrets enable -path="${MOUNT_POINT}" -version=2 kv
fi

bao write "${MOUNT_POINT}/config" max_versions=20 >/dev/null

cat >"${POLICY_FILE}" <<POLICY
path "${MOUNT_POINT}/data/*" {
  capabilities = ["create", "read", "update", "patch"]
}

path "${MOUNT_POINT}/metadata/*" {
  capabilities = ["create", "update", "delete"]
}
POLICY

bao policy write jumpserver "${POLICY_FILE}" >/dev/null

if [ -n "${SERVICE_TOKEN}" ]; then
  if ! bao token lookup "${SERVICE_TOKEN}" >/dev/null 2>&1; then
    bao token create \
      -id="${SERVICE_TOKEN}" \
      -policy=jumpserver \
      -orphan \
      -no-default-policy \
      -format=json >"${SERVICE_TOKEN_FILE}"
    chmod 600 "${SERVICE_TOKEN_FILE}" 2>/dev/null || true
  fi
fi
