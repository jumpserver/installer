#!/usr/bin/env bash

function jdmc_node_dir() { get_config_or_env JDMC_NODE_DIR /etc/jdmc/node; }

function use_container_jdmc() {
  is_jdmc_enabled || return 1
  [[ "$(get_config_or_env HA_MODE 0)" != 1 ]] || return 1
  ! jdmc_ha_lifecycle_present "$(get_current_jdmc_data_dir)/ha" &&
    ! jdmc_ha_lifecycle_present "$(get_legacy_kotl_data_dir)/ha"
}

# Provision the shared Core/JDMC enrollment secret and persistent node name.
# Publish the complete initial bundle by directory rename so interrupted or
# concurrent installs never rotate an existing node.
function jdmc_create_identity() (
  set -eu
  local node=$1 tmp requested
  [[ ! -e "${node}/identity" ]] || return 0
  umask 077
  tmp=$(mktemp -d "${node}/.identity.XXXXXX")
  trap 'rm -rf -- "$tmp"' EXIT
  cd "$tmp"
  mkdir core registration
  openssl rand -hex 32 > core/enrollment-secret || return 1
  install -m 0440 -g 10001 core/enrollment-secret registration/enrollment-secret
  chgrp 10001 registration
  chmod 0750 registration
  requested=$(get_config_or_env JDMC_CORE_NODE_NAME)
  [[ -n "$requested" ]] || requested="jdmc-$(openssl rand -hex 12)"
  [[ "$requested" =~ ^[[:alnum:]_-]{1,64}$ ]] || { echo "Invalid JDMC_CORE_NODE_NAME" >&2; return 1; }
  printf '%s\n' "$requested" > node-name
  [[ -s core/enrollment-secret && -s registration/enrollment-secret && -s node-name ]] || return 1
  mv -T "$tmp" "${node}/identity"
)

# The Web UI and Core use the same listener. The internal SNI certificate is
# independent of uploaded Web certificates. Keep both node TLS roles in one
# immutable, atomically published bundle, including when upgrading older nodes.
function jdmc_prepare_transport() (
  set -eu
  local identity=$1 stage bundle="$1/transport" role san
  umask 077
  if [[ ! -d "$bundle" ]]; then
    stage=$(mktemp -d "$identity/.transport.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    cd "$stage" || return 1
    mkdir callback web || return 1
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
      -subj '/CN=JumpServer JDMC node CA' -keyout issuer.key -out ca.crt \
      -config <(printf '%s\n' '[req]' 'distinguished_name=dn' 'x509_extensions=ca' '[dn]' '[ca]' \
        'basicConstraints=critical,CA:TRUE,pathlen:0' 'keyUsage=critical,keyCertSign,cRLSign') \
      >/dev/null 2>&1 || return 1
    for role in callback web; do
      if [[ "$role" == callback ]]; then
        san='DNS:jdmc.host.internal,DNS:host.docker.internal'
      elif [[ -s "$identity/web/server.crt" && -s "$identity/web/server.key" && -s "$identity/tls/core-ca.crt" ]]; then
        # Keep the existing private proxy identity during a rolling upgrade.
        cp -- "$identity/web/server.crt" "$identity/web/server.key" web/ || return 1
        cp -- "$identity/tls/core-ca.crt" core-ca.crt || return 1
        continue
      else
        san='IP:127.0.0.1,DNS:localhost'
        cp ca.crt core-ca.crt || return 1
      fi
      printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature,keyEncipherment' \
        'extendedKeyUsage=serverAuth' "subjectAltName=$san" > extensions || return 1
      openssl req -new -newkey rsa:2048 -nodes -subj "/CN=JDMC $role" \
        -keyout "$role/server.key" -out request.csr >/dev/null 2>&1 || return 1
      openssl x509 -req -sha256 -days 1825 -in request.csr -CA ca.crt -CAkey issuer.key \
        -CAcreateserial -extfile extensions -out "$role/server.crt" >/dev/null 2>&1 || return 1
    done
    rm -f issuer.key ca.srl extensions request.csr || return 1
    chmod 0444 ca.crt core-ca.crt callback/server.crt web/server.crt || return 1
    chgrp 10001 callback callback/server.key && chmod 0750 callback && chmod 0440 callback/server.key || return 1
    mv -T "$stage" "$bundle" || return 1
  fi
  # Only the public trust anchor crosses from each server to its TLS client.
  local pair source dest
  for pair in 'ca.crt:core/callback-ca.crt' 'core-ca.crt:registration/core-ca.crt'; do
    source="$bundle/${pair%%:*}"; dest="$identity/${pair#*:}"
    if [[ ! -e "$dest" ]]; then ln -- "$source" "$dest" || return 1; fi
    cmp -s "$source" "$dest" || { log_error "Conflicting JDMC trust file: $dest"; return 1; }
  done
)

function jdmc_configure_callback() {
  local addr host port bridge_ip=''
  addr=$(get_config_or_env JDMC_WEB_ADDR 0.0.0.0:9898)
  host=${addr%:*}
  port=${addr##*:}
  [[ "$addr" == *:* && "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port > 0 && 10#$port <= 65535 )) || {
    log_error "Invalid JDMC_WEB_ADDR: $addr"; return 1
  }
  host=${host#\[}; host=${host%\]}
  case "$host" in
    ''|'::'|0.0.0.0) host=host-gateway ;;
    127.*|'::1'|localhost)
      host=host-gateway
      if [[ -z "$(get_config_or_env JDMC_HTTPS_URL)" ]]; then
        # The host-network JDMC can bind the gateway directly without making
        # its loopback-only management routes available on any other address.
        bridge_ip=$(timeout 4 docker network inspect bridge --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' 2>/dev/null |
          awk '/^[0-9a-fA-F:.]+$/ && !found {print; found=1}') || bridge_ip=''
        if [[ -n "$bridge_ip" ]]; then
          host=$bridge_ip
        else
          log_warn "Docker bridge gateway unavailable; host login is available on $addr. Run jmsctl start jdmc after Docker is ready to enable Core callbacks."
        fi
      fi
      ;;
    *)
      if [[ ! "$host" =~ ^[0-9.]+$ && "$host" != *:* ]]; then
        host=$(getent ahosts "$host" | awk 'NR == 1 {print $1}')
        [[ -n "$host" ]] || { log_error "Cannot resolve JDMC_WEB_ADDR: $addr"; return 1; }
      fi ;;
  esac
  set_config JDMC_CALLBACK_PORT "$((10#$port))" && set_config JDMC_CALLBACK_HOST "$host" &&
    set_config JDMC_CALLBACK_BRIDGE_IP "$bridge_ip"
}

function configure_container_jdmc() (
  set -e
  local node token configured enrolled tmp
  node=$(jdmc_node_dir)
  [[ "$node" == /* && "$node" != / && ! -L "$node" ]] || return 1
  if [[ -e "$node" ]]; then
    [[ -d "$node" && "$(stat -c '%u:%a' "$node")" == 0:700 ]] ||
      { log_error "JDMC_NODE_DIR must be a root-owned private directory"; return 1; }
  else
    install -d -m 0700 "$node" || return 1
  fi
  exec 9>"$node/.identity.lock"
  flock -x 9 || return 1
  [[ ! -L "$node/identity" ]] && jdmc_create_identity "$node" || return 1
  jdmc_prepare_transport "$node/identity" || return 1
  jdmc_configure_callback || return 1
  enrolled=$(cat "$node/identity/node-name") || return 1
  configured=$(get_config_or_env JDMC_CORE_NODE_NAME)
  [[ -z "$configured" || "$configured" == "$enrolled" ]] || { log_error "JDMC node identity differs from the saved node name"; return 1; }
  set_config JDMC_CORE_NODE_NAME "$enrolled" || return 1
  # Keep the token out of CLI arguments, Compose config and process output.
  token=$(get_config_or_env BOOTSTRAP_TOKEN)
  [[ -n "$token" && "$token" != *[[:space:]]* ]] || { log_error "Missing or invalid BOOTSTRAP_TOKEN"; return 1; }
  tmp=$(mktemp "$node/identity/registration/.bootstrap.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' EXIT
  printf '%s\n' "$token" > "$tmp" && chgrp 10001 "$tmp" && chmod 0440 "$tmp" &&
    mv -fT "$tmp" "$node/identity/registration/bootstrap-token" || return 1
  gen_safe_config >/dev/null
)

function jdmc_extract_release() (
  set -eu
  local image=$1 dir=$2 staging cid=''
  if [[ -d "$dir" ]]; then
    docker tag "$image" "jdmc-runtime:${dir##*/}"
    return
  fi
  staging=$(mktemp -d "${dir}.XXXXXX") || return 1
  trap 'if [[ -n "$cid" ]]; then docker rm "$cid" >/dev/null || :; fi; rm -rf -- "$staging"' EXIT
  cid=$(docker create --network none --entrypoint /bin/true "$image") || return 1
  docker cp "$cid:/opt/jdmc/deploy/docker/." "$staging/" || return 1
  for file in host-compose.sh compose.yml compose.host-management.yml compose.halcli.yml compose.g2hproxy.yml; do
    [[ -f "$staging/$file" && ! -L "$staging/$file" ]] || { log_error "Missing JDMC deployment file: $file"; return 1; }
  done
  docker tag "$image" "jdmc-runtime:${dir##*/}" || return 1
  printf '%s\n' "jdmc-runtime:${dir##*/}" > "$staging/image"
  mv -T "$staging" "$dir"
)

function jdmc_migrate_backup_mounts() (
  local node=$1 state=$2 old=$3 image=$4 legacy config candidate default stage
  # A failed native KOTL preflight may have cached an empty or obsolete
  # store. Rediscover it until the data migration actually starts.
  if [[ -e "$node/backup-mounts" && ( "$old" == "$state" || -n ${5:-} || -L "$node/release" || -d "$state/.jdmc-layout-transition" ) ]]; then
    return 0
  fi
  if [[ -n ${5:-} ]]; then
    # Use the running deployment's approved mount list before considering
    # any of the native files left beside its volumes.
    stage=$(mktemp -d "$node/.backup-mounts.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$5" |
      python3 -c 'import pathlib,sys
values = dict(line.rstrip("\n").split("=",1) for line in sys.stdin if "=" in line)
for key, field in (("root","JDMC_HOST_BACKUP_DIR"),("logs","JDMC_HOST_BACKUP_LOG_DIRS"),("replays","JDMC_HOST_BACKUP_REPLAY_DIRS")):
    (pathlib.Path(sys.argv[1]) / key).write_text(values.get(field, "") + "\n")' "$stage" || return 1
    mv -T "$stage" "$node/backup-mounts"
    return
  fi
  default="$old/backup"
  config="$old/jdmc.yaml"
  [[ -f "$config" || ! -f "$old/kotl.yaml" ]] || config="$old/kotl.yaml"
  candidate=$default
  if [[ -f "$config" && ! -L "$config" && "$(stat -c %u "$config")" == 0 ]]; then
    legacy=$(docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
      --mount "type=bind,source=$config,target=/legacy.yaml,readonly" --entrypoint /usr/local/bin/cfgcli \
      "$image" get backup-path /legacy.yaml) || return 1
    [[ -z "$legacy" ]] || candidate=$legacy
  fi
  stage=$(mktemp -d "$node/.backup-mounts.XXXXXX") || return 1
  trap 'rm -rf -- "$stage"' EXIT
  python3 "$PROJECT_DIR/scripts/gists/jdmc-backup.py" "$stage" "$state" "$node" \
    "$(get_config_or_env VOLUME_DIR /data/jumpserver)" "$candidate" "$default" "$config" "${6:-}" || return 1
  local root
  root=$(cat "$stage/root") || return 1
  # Default stores in older native installations were created with mode 0755.
  # Tighten only a real root-owned native backup store, never a configured
  # arbitrary parent such as /srv or /var.
  if [[ -d "$root" && ! -L "$root" && "$(stat -c '%u:%g' "$root")" == 0:0 &&
        "$(readlink -e "$root")" == "$root" && ( "$root" == "$default" || -f "$root/backup_config.json" ) ]]; then
    chmod 0700 "$root" || return 1
  fi
  if [[ -d "$node/backup-mounts" ]]; then
    local field
    for field in logs replays root; do
      mv -fT "$stage/$field" "$node/backup-mounts/$field" || return 1
    done
  else
    mv -T "$stage" "$node/backup-mounts"
  fi
)

function jdmc_compose() (
  local node=$1 release=$2 local_core_url
  shift 2
  export JDMC_IMAGE JDMC_REGISTRATION_DIR="$node/identity/registration"
  export JDMC_CORE_ENROLLMENT_SECRET_FILE=/run/jdmc/registration/enrollment-secret
  export JDMC_TLS_DIR="$node/identity/transport/callback"
  export JDMC_CORE_NODE_NAME JDMC_CORE_URL JDMC_CORE_CA_FILE JDMC_WEB_ADDR JDMC_HOST_BACKUP_DIR JUMPSERVER_VOLUME_DIR
  export JDMC_HOST_DISK_DEVICES JDMC_HOST_DISK_MOUNTPOINTS JDMC_HOST_DISK_SHARED_PARENT JDMC_HOST_LV_MINORS
  export JDMC_DOCKER_HOST JDMC_DOCKER_SOCK JDMC_HOST_BACKUP_LOG_DIRS JDMC_HOST_BACKUP_REPLAY_DIRS
  JDMC_IMAGE=$(cat "$release/image") || return 1
  if [[ -n ${JDMC_OFFLINE_IDENTITY:-} ]]; then
    JDMC_REGISTRATION_DIR="$JDMC_OFFLINE_IDENTITY/registration"
    JDMC_TLS_DIR="$JDMC_OFFLINE_IDENTITY/tls"
    JDMC_CORE_NODE_NAME=$(get_config_or_env JDMC_CORE_NODE_NAME)
  else
    JDMC_CORE_NODE_NAME=$(cat "$node/identity/node-name") || return 1
  fi
  local_core_url="https://127.0.0.1:$(get_config_or_env JDMC_API_PORT 9897)"
  JDMC_CORE_URL=$(get_config_or_env JDMC_CORE_URL "$local_core_url")
  JDMC_CORE_CA_FILE=$(get_config_or_env JDMC_CORE_CA_FILE)
  if [[ "${JDMC_CORE_URL%/}" == "$local_core_url" && -z "$JDMC_CORE_CA_FILE" ]]; then
    JDMC_CORE_CA_FILE=/run/jdmc/registration/core-ca.crt
  fi
  JDMC_WEB_ADDR=$(get_config_or_env JDMC_WEB_ADDR 0.0.0.0:9898)
  export JDMC_CALLBACK_BRIDGE_IP
  JDMC_CALLBACK_BRIDGE_IP=$(get_config JDMC_CALLBACK_BRIDGE_IP)
  JUMPSERVER_VOLUME_DIR=$(get_config_or_env VOLUME_DIR /data/jumpserver)
  local name
  for name in JDMC_HOST_DISK_DEVICES JDMC_HOST_DISK_MOUNTPOINTS JDMC_HOST_DISK_SHARED_PARENT JDMC_HOST_LV_MINORS JDMC_HOST_BACKUP_LOG_DIRS JDMC_HOST_BACKUP_REPLAY_DIRS JDMC_DOCKER_HOST JDMC_DOCKER_SOCK; do
    printf -v "$name" '%s' "$(get_config_or_env "$name")"
  done
  if [[ -f "$node/backup-mounts/root" ]]; then
    JDMC_HOST_BACKUP_DIR=$(get_config_or_env JDMC_HOST_BACKUP_DIR "$(cat "$node/backup-mounts/root")")
    JDMC_HOST_BACKUP_LOG_DIRS=$(get_config_or_env JDMC_HOST_BACKUP_LOG_DIRS "$(cat "$node/backup-mounts/logs")")
    JDMC_HOST_BACKUP_REPLAY_DIRS=$(get_config_or_env JDMC_HOST_BACKUP_REPLAY_DIRS "$(cat "$node/backup-mounts/replays")")
  else
    JDMC_HOST_BACKUP_DIR=$(get_config_or_env JDMC_HOST_BACKUP_DIR "$(get_current_jdmc_data_dir)/backup")
  fi
  JDMC_HOST_BACKUP_DIR=${storage_backup:-$JDMC_HOST_BACKUP_DIR}
  if [[ ! -e "$JDMC_HOST_BACKUP_DIR" ]]; then
    install -d -m 0700 "$JDMC_HOST_BACKUP_DIR" || return 1
  fi
  # A fresh node has no published installer symlink yet. Resolve the source
  # before Compose so a later release switch also changes the bind identity.
  local installer=/opt/current/installer
  if [[ ! -e "$installer" && ! -L "$installer" ]]; then installer="$PROJECT_DIR"; fi
  export JDMC_INSTALLER_SOURCE
  JDMC_INSTALLER_SOURCE=$(cd -- "$installer" && pwd -P) || return 1
  export JDMC_NODE_DIR="$node" JDMC_STATE_DIR
  JDMC_STATE_DIR=$(get_current_jdmc_data_dir) || return 1
  bash "$release/host-compose.sh" --project-name jdmc -f - "$@" <<'YAML'
services:
  jdmc:
    environment:
      # Keep the deployed edition when JDMC replays installer commands.
      USE_XPACK: "1"
    volumes:
      - type: bind
        source: ${JDMC_INSTALLER_SOURCE}
        target: /opt/current/installer
        read_only: true
        bind:
          create_host_path: false
YAML
)

function container_jdmc_action() (
  set -eo pipefail
  local operation=$1 node image id dir old state kotl unit ids live source work mode storage_backup backup_override legacy_state
  local -a flags=()
  node=$(jdmc_node_dir)
  case "$operation" in
    ps|logs|stop|down)
      ids=$(docker ps -a -q --filter label=com.docker.compose.project=jdmc --filter label=com.docker.compose.service=jdmc) || return 1
      [[ -n "$ids" ]] || return 0
      case "$operation" in
        ps) docker ps -a --filter label=com.docker.compose.project=jdmc --filter label=com.docker.compose.service=jdmc ;;
        logs) docker logs --tail 100 -f "${ids%%$'\n'*}" ;;
        stop) docker stop $ids ;;
        down) docker stop $ids && docker rm $ids ;;
      esac
      return
      ;;
  esac
  if ! configure_container_jdmc; then
    # An unhealthy Core identity cannot prevent access to the host recovery UI.
    # Keep this mount separate so the next successful preparation can atomically
    # install the real keys without treating an empty directory as an identity.
    [[ -d "$node" && ! -L "$node" && "$(stat -c '%u:%a' "$node")" == 0:700 ]] || return 1
    export JDMC_OFFLINE_IDENTITY="$node/offline"
    install -d -m 0750 -g 10001 "$JDMC_OFFLINE_IDENTITY"/{tls,registration} || return 1
    log_warn "Core identity unavailable; starting JDMC with host PAM. Restore the node credentials and run jmsctl start jdmc."
  fi
  exec 8>"$node/.lifecycle.lock"
  flock -x 8 || return 1
  image=$(get_jdmc_image)
  id=$(docker image inspect --format '{{.Id}}' "$image") || return 1
  [[ "$id" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
  dir="$node/releases/${id#sha256:}"
  install -d -m 0700 "$node/releases" || return 1
  jdmc_extract_release "$id" "$dir" || return 1
  state=$(get_current_jdmc_data_dir) || return 1
  kotl=$(get_legacy_kotl_data_dir) || return 1
  old=$state
  grep -Fq '/data/jdmc/state' "$dir/compose.yml" || { log_error "The selected JDMC image does not support the new storage layout"; return 1; }
  live=$(docker ps -aq --filter label=com.docker.compose.project=jdmc --filter label=com.docker.compose.service=jdmc) || return 1
  [[ "$live" != *$'\n'* ]] || { log_error "Ambiguous JDMC containers"; return 1; }
  if [[ -z "$live" && ! -L "$node/release" && ! -e "$state/jdmc.yaml" && -d "$kotl" ]]; then
    old=$kotl
  fi
  legacy_state=$(get_config_or_env JDMC_STATE_DIR "$state/container")
  backup_override=$(get_config_or_env JDMC_HOST_BACKUP_DIR)
  work=$(mktemp -d "$node/.layout-run.XXXXXX") || return 1
  trap 'rm -rf -- "$work"' EXIT
  jdmc_migrate_backup_mounts "$node" "$state" "$old" "$id" "$live" "$backup_override" || return 1
  local layout="$PROJECT_DIR/scripts/gists/jdmc-layout.py"
  python3 "$layout" plan "$state" "$work" "$legacy_state" "$old" \
    "$(cat "$node/backup-mounts/root")" "$backup_override" "$live" "$id" || return 1
  storage_backup=$(cat "$work/new-backup") || return 1
  mode=$(cat "$work/mode") || return 1
  # Validate the target on this host while the native service can still serve.
  jdmc_compose "$node" "$dir" config --quiet || return 1
  docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --entrypoint /opt/jdmc/jdmc "$id" -v >/dev/null || return 1

  for unit in "$JDMC_SERVICE_NAME" "$JDMC_LEGACY_SERVICE_NAME"; do
    jdmc_unit_exists "$unit" || continue
    # The full-package runner must also keep the native unit retired on retry.
    if [[ -n ${JDMC_UPGRADE_LOG_DIR:-} ]]; then
      local marker="$JDMC_UPGRADE_LOG_DIR/jdmc-container-cutover"
      touch -- "$marker" && sync "$marker" "$JDMC_UPGRADE_LOG_DIR" || return 1
    fi
    if systemctl is-enabled --quiet "$unit"; then systemctl disable "$unit" || return 1; fi
    systemctl stop "$unit" || return 1
  done
  if [[ "$mode" == move ]]; then
    source=$(cat "$work/source-cid") || return 1
    if [[ -n "$live" && "$live" == "$source" ]]; then docker stop "$live" || return 1; fi
    python3 "$layout" apply "$state" "$work" "$id" || return 1
  fi
  [[ "$operation" != restart ]] || flags+=(--force-recreate)
  if ! jdmc_compose "$node" "$dir" up -d --wait "${flags[@]}"; then
    log_error "JDMC container did not become ready. Correct the startup error and retry the same installer operation."
    return 1
  fi
  ln -sfnT "$dir" "$node/.next-release" && mv -fT "$node/.next-release" "$node/release" || return 1
  if [[ "$storage_backup" != "$(cat "$node/backup-mounts/root")" ]]; then
    printf '%s\n' "$storage_backup" > "$work/backup-root" && mv -fT "$work/backup-root" "$node/backup-mounts/root" || return 1
  fi
  python3 "$layout" commit "$state" "$work" || return 1
  local unshare socket
  unshare="$(get_config_or_env VOLUME_DIR /data/jumpserver)/core/data/unshare"
  for socket in "$unshare"/jdmc.sock{,.*} "$unshare"/kotl.sock{,.*}; do
    [[ ! -S "$socket" || -L "$socket" ]] || rm -- "$socket" || return 1
  done
  remove_config JDMC_SOCK_PATH || return 1
  cleanup_jdmc_legacy_switches || return 1
)

function install_jdmc_boot_unit() {
  local unit_dir=${JDMC_UNIT_DIR:-/etc/systemd/system} name=jumpserver-jdmc-container.service
  local src="$PROJECT_DIR/config_init/jdmc/jumpserver-jdmc-container.service"
  [[ -d /run/systemd/system ]] || { log_warn "systemd is unavailable; run jmsctl start jdmc after boot to refresh host mounts"; return 0; }
  if [[ -e "$unit_dir/$name" || -L "$unit_dir/$name" ]]; then
    [[ ! -L "$unit_dir/$name" ]] && grep -Fxq '# Managed by the JumpServer installer' "$unit_dir/$name" || return 1
  fi
  if ! cmp -s "$src" "$unit_dir/$name"; then
    install -m 0644 "$src" "$unit_dir/$name" && systemctl daemon-reload || return 1
  fi
  systemctl enable "$name"
}

function remove_jdmc_boot_unit() {
  local file=${JDMC_UNIT_DIR:-/etc/systemd/system}/jumpserver-jdmc-container.service
  [[ -f "$file" ]] || return 0
  [[ ! -L "$file" ]] && grep -Fxq '# Managed by the JumpServer installer' "$file" || return 1
  systemctl disable --now jumpserver-jdmc-container.service && rm -- "$file" && systemctl daemon-reload
}
