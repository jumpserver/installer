#!/usr/bin/env bash

function jdmc_installer_dir() { printf '%s/.installer\n' "$(get_current_jdmc_data_dir)"; }

# Labels select candidates. Bind mounts identify the installation, including
# its previous data root when VOLUME_DIR and the installer release both change.
function jdmc_container_id() {
  local state=$1 cid management origin release installer
  cid=$(docker ps -aq --filter label=com.docker.compose.project=jdmc --filter label=com.docker.compose.service=jdmc) || return 1
  [[ "$cid" != *$'\n'* ]] || { log_error "Ambiguous JDMC containers"; return 1; }
  [[ -n "$cid" ]] || return 0
  management=$(docker inspect -f '{{range .Mounts}}{{if and (eq .Type "bind") (eq .Destination "/data/jdmc/management")}}{{.Source}}{{end}}{{end}}' "$cid") || return 1
  if [[ ! "$management" -ef "$state/management" ]]; then
    origin=$(docker inspect -f '{{println (index .Config.Labels "com.docker.compose.project.working_dir")}}{{range .Mounts}}{{if and (eq .Type "bind") (eq .Destination "/opt/current/installer")}}{{.Source}}{{end}}{{end}}' "$cid") || return 1
    release=${origin%%$'\n'*}
    installer=${origin#*$'\n'}
    if [[ "$management" != /*/management || "${release%/*}" != "${management%/management}/.installer/releases" ||
          ! ( "$installer" -ef "$PROJECT_DIR" || "$installer" -ef /opt/current/installer ) ]]; then
      log_error "Cannot confirm the JDMC container belongs to this installation: $cid"
      return 1
    fi
  fi
  printf '%s\n' "$cid"
}

function jdmc_mounted_config_root() {
  local cid source
  cid=${1-$(jdmc_container_id "$(get_current_jdmc_data_dir)")} || return 1
  [[ -n "$cid" ]] || return 0
  source=$(docker inspect -f '{{range .Mounts}}{{if and (eq .Type "bind") (eq .Destination "/data/jdmc/config/core")}}{{.Source}}{{end}}{{end}}' "$cid") || return 1
  case "$source" in
    /*/config/core) printf '%s\n' "${source%/config/core}" ;;
    /*/.installer/offline/core) printf '%s\n' "${source%/.installer/offline/core}" ;;
  esac
}

# Publish each prepared file by rename. Both directory bind mounts and existing
# credentials survive an interrupted first installation or a repeated prepare.
function jdmc_publish_file() (
  local source=$1 dest=$2 tmp
  [[ -f "$source" && ! -L "$source" && ! -L "$dest" ]] || return 1
  if [[ -e "$dest" ]]; then
    [[ -f "$dest" && "$(stat -c %u "$dest")" == 0 ]] && cmp -s "$source" "$dest"
    return
  fi
  tmp=$(mktemp -- "${dest}.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' EXIT
  install -m 0400 -- "$source" "$tmp" && mv -fT -- "$tmp" "$dest"
)

function jdmc_create_identity() (
  set -eu
  local core=$1 source=$2 node=$3 pending="$3/.pending-identity" tmp file suffix
  if [[ ! -d "$pending" ]]; then
    if [[ -s "$core/node-name" && -s "$core/enrollment-secret" ]]; then return 0; fi
    [[ ! -e "$core/node-name" && ! -e "$core/enrollment-secret" ]] || return 1
    umask 077
    tmp=$(mktemp -d "$node/.identity.XXXXXX") || return 1
    trap 'rm -rf -- "$tmp"' EXIT
    if [[ ! "$source" -ef "$core" ]]; then
      for file in node-name enrollment-secret; do
        jdmc_publish_file "$source/$file" "$tmp/$file" || return 1
      done
    else
      openssl rand -hex 32 > "$tmp/enrollment-secret" || return 1
      suffix=$(openssl rand -hex 12) || return 1
      printf 'jdmc-%s\n' "$suffix" > "$tmp/node-name" || return 1
    fi
    mv -T -- "$tmp" "$pending" || return 1
  fi
  for file in node-name enrollment-secret; do
    jdmc_publish_file "$pending/$file" "$core/$file" || return 1
  done
  rm -rf -- "$pending"
)

# Core authenticates the JDMC listener using this persistent node CA.
function jdmc_prepare_transport() (
  set -eu
  local node=$1 core=$2 source=$3 stage file bundle="$1/transport" pending="$1/.pending-transport"
  umask 077
  for file in "$bundle" "$bundle/callback"; do
    [[ ! -L "$file" ]] || return 1
    [[ -d "$file" ]] || install -d -m 0700 "$file" || return 1
    [[ "$(find "$file" -maxdepth 0 -uid 0 ! -perm /022 -print)" == "$file" ]] || return 1
  done
  if [[ ! -d "$pending" && ! -s "$bundle/ca.crt" ]]; then
    [[ ! -e "$bundle/ca.crt" && ! -e "$bundle/callback/server.crt" && ! -e "$bundle/callback/server.key" ]] || return 1
    stage=$(mktemp -d "$node/.transport.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    cd "$stage" || return 1
    mkdir callback || return 1
    if [[ ! "$source" -ef "$bundle" ]]; then
      for file in ca.crt callback/server.crt callback/server.key; do
        [[ -f "$source/$file" && ! -L "$source/$file" ]] || return 1
        install -m 0400 -- "$source/$file" "$file" || return 1
      done
    else
      openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
        -subj '/CN=JumpServer JDMC node CA' -keyout issuer.key -out ca.crt \
        -config <(printf '%s\n' '[req]' 'distinguished_name=dn' 'x509_extensions=ca' '[dn]' '[ca]' \
          'basicConstraints=critical,CA:TRUE,pathlen:0' 'keyUsage=critical,keyCertSign,cRLSign') \
        >/dev/null 2>&1 || return 1
      printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature,keyEncipherment' \
        'extendedKeyUsage=serverAuth' 'subjectAltName=DNS:jdmc.host.internal' > extensions || return 1
      openssl req -new -newkey rsa:2048 -nodes -subj '/CN=JDMC callback' \
        -keyout callback/server.key -out request.csr >/dev/null 2>&1 || return 1
      openssl x509 -req -sha256 -days 1825 -in request.csr -CA ca.crt -CAkey issuer.key \
        -CAcreateserial -extfile extensions -out callback/server.crt >/dev/null 2>&1 || return 1
      rm -f issuer.key ca.srl extensions request.csr || return 1
    fi
    chmod 0400 ca.crt callback/server.crt callback/server.key || return 1
    mv -T "$stage" "$pending" || return 1
  fi
  if [[ -d "$pending" ]]; then
    for file in ca.crt callback/server.crt callback/server.key; do
      jdmc_publish_file "$pending/$file" "$bundle/$file" || return 1
    done
    rm -rf -- "$pending" || return 1
  fi
  for file in ca.crt callback/server.crt callback/server.key; do
    [[ "$(find "$bundle/$file" -maxdepth 0 -type f -uid 0 ! -perm /022 -print)" == "$bundle/$file" ]] || return 1
  done
  chmod 0400 "$bundle/callback/server.key" || return 1
  jdmc_publish_file "$bundle/ca.crt" "$core/callback-ca.crt"
)

function jdmc_configure_callback() (
  local directory=$1 addr host port tmp bridge_ip=''
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
      # Bind only the callback routes on the Docker gateway for a loopback Web listener.
      bridge_ip=$(timeout 4 docker network inspect bridge --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' 2>/dev/null |
        awk '/^[0-9a-fA-F:.]+$/ && !found {print; found=1}') || bridge_ip=''
      if [[ -n "$bridge_ip" ]]; then
        host=$bridge_ip
      else
        log_warn "Docker bridge gateway unavailable; host login is available on $addr. Run jmsctl start jdmc after Docker is ready to enable Core callbacks."
      fi
      ;;
    *)
      if [[ ! "$host" =~ ^[0-9.]+$ && "$host" != *:* ]]; then
        host=$(getent ahosts "$host" | awk 'NR == 1 {print $1}')
        [[ -n "$host" ]] || { log_error "Cannot resolve JDMC_WEB_ADDR: $addr"; return 1; }
      fi ;;
  esac
  port=$((10#$port))
  [[ ! -L "$directory/port" && ( ! -e "$directory/port" || -f "$directory/port" ) ]] || return 1
  if [[ ! -f "$directory/port" || "$(< "$directory/port")" != "$port" ]]; then
    tmp=$(mktemp "$directory/.port.XXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    printf '%s\n' "$port" > "$tmp" && chmod 0400 "$tmp" && mv -fT -- "$tmp" "$directory/port" || return 1
  fi
  set_config JDMC_CALLBACK_HOST "$host" && set_config JDMC_CALLBACK_BRIDGE_IP "$bridge_ip"
)

function configure_container_jdmc() (
  set -e
  local state node core source_root dir
  state=$(get_current_jdmc_data_dir) || return 1
  node="$state/.installer"
  core="$state/config/core"
  for dir in "$state" "$node" "$state/config" "$core"; do
    [[ "$dir" == /* && "$dir" != / && "$(realpath -m -- "$dir")" == "$dir" ]] || return 1
    if [[ -e "$dir" ]]; then
      [[ "$(find "$dir" -maxdepth 0 -type d -uid 0 ! -perm /022 -print)" == "$dir" ]] || return 1
    else
      install -d -m 0700 "$dir" || return 1
    fi
  done
  chmod 0700 "$node" "$core" || return 1
  exec 9>"$node/.identity.lock"
  flock -x 9 || return 1
  source_root=$state
  if [[ ! -s "$core/enrollment-secret" || ! -s "$node/transport/ca.crt" ]]; then
    source_root=$(jdmc_mounted_config_root "$@") || return 1
    source_root=${source_root:-$state}
    if [[ "$source_root" != "$state" ]]; then
      for dir in "$source_root/config/core" "$source_root/.installer"; do
        [[ "$(readlink -e -- "$dir")" == "$dir" && "$(stat -c '%u:%a' "$dir")" == 0:700 ]] || return 1
      done
    fi
  fi
  jdmc_create_identity "$core" "$source_root/config/core" "$node" || return 1
  [[ -f "$core/node-name" && ! -L "$core/node-name" && "$(< "$core/node-name")" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || return 1
  [[ -s "$core/enrollment-secret" && "$(find "$core/enrollment-secret" -maxdepth 0 -type f -uid 0 -print)" == "$core/enrollment-secret" ]] || return 1
  chmod 0400 "$core/enrollment-secret" || return 1
  jdmc_prepare_transport "$node" "$core" "$source_root/.installer/transport" || return 1
  jdmc_configure_callback "$core" || return 1
  gen_safe_config >/dev/null
)

function jdmc_extract_release() (
  set -eu
  local image=$1 dir=$2 source=$2 file cid=''
  [[ ! -L "$dir" ]] || { log_error "Invalid JDMC release directory: $dir"; return 1; }
  if [[ ! -d "$dir" ]]; then
    source=$(mktemp -d "${dir}.XXXXXX") || return 1
    trap 'if [[ -n "$cid" ]]; then docker rm "$cid" >/dev/null || :; fi; rm -rf -- "$source"' EXIT
    cid=$(docker create --network none --entrypoint /bin/true "$image") || return 1
    docker cp "$cid:/opt/jdmc/deploy/docker/." "$source/" || return 1
  fi
  for file in host-compose.sh jdmc-layout.py compose.yml compose.host-management.yml compose.halcli.yml compose.g2hproxy.yml; do
    [[ -f "$source/$file" && -s "$source/$file" && ! -L "$source/$file" ]] || {
      log_error "Missing or invalid JDMC deployment file $file in release $image"
      return 1
    }
  done
  [[ "$source" == "$dir" ]] || mv -T "$source" "$dir"
)

function jdmc_compose() (
  local node=$1 release=$2
  export JDMC_HOST_BACKUP_DIR="$3"
  shift 3
  export JDMC_STATE_DIR
  JDMC_STATE_DIR=$(get_current_jdmc_data_dir) || return 1
  export JDMC_IMAGE="sha256:${release##*/}" JDMC_REGISTRATION_DIR="$JDMC_STATE_DIR/config/core"
  export JDMC_TLS_DIR="$node/transport/callback" JDMC_WEB_ADDR JUMPSERVER_VOLUME_DIR
  if [[ -n ${JDMC_OFFLINE_IDENTITY:-} ]]; then
    JDMC_REGISTRATION_DIR="$JDMC_OFFLINE_IDENTITY/core"
    JDMC_TLS_DIR="$JDMC_OFFLINE_IDENTITY/tls"
  fi
  JDMC_WEB_ADDR=$(get_config_or_env JDMC_WEB_ADDR 0.0.0.0:9898)
  export JDMC_CALLBACK_BRIDGE_IP
  JDMC_CALLBACK_BRIDGE_IP=$(get_config JDMC_CALLBACK_BRIDGE_IP)
  JUMPSERVER_VOLUME_DIR=$(get_config_or_env VOLUME_DIR /data/jumpserver)
  local name
  for name in JDMC_HOST_DISK_DEVICES JDMC_HOST_DISK_MOUNTPOINTS JDMC_HOST_DISK_SHARED_PARENT JDMC_HOST_LV_MINORS JDMC_DOCKER_SOCK; do
    export "$name=$(get_config_or_env "$name")"
  done
  export JDMC_HOST_BACKUP_LOG_DIRS JDMC_HOST_BACKUP_REPLAY_DIRS
  JDMC_HOST_BACKUP_LOG_DIRS=$(get_config_or_env JDMC_HOST_BACKUP_LOG_DIRS "$(cat "$node/backup-mounts/logs")")
  JDMC_HOST_BACKUP_REPLAY_DIRS=$(get_config_or_env JDMC_HOST_BACKUP_REPLAY_DIRS "$(cat "$node/backup-mounts/replays")")
  if [[ ! -e "$JDMC_HOST_BACKUP_DIR" ]]; then
    install -d -m 0700 "$JDMC_HOST_BACKUP_DIR" || return 1
  fi
  # Bind the release whose command is running, including during the first upgrade.
  export JDMC_INSTALLER_SOURCE
  JDMC_INSTALLER_SOURCE=$(cd -- "$PROJECT_DIR" && pwd -P) || return 1
  bash "$release/host-compose.sh" --project-name jdmc -f - "$@" <<'YAML'
services:
  jdmc:
    pull_policy: never
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

# Return the backup bind only if the published release and all four live
# data mounts still match. A stopped container retains the same mount spec.
function jdmc_current_backup() {
  local node=$1 release=$2 state=$3 cid=$4 requested=$5 backup info part source journal
  [[ -n "$cid" && -d "$state" && -L "$node/release" && "$node/release" -ef "$release" ]] || return 1
  for journal in "$state"/.jdmc-layout-{transition,committed}; do
    jdmc_path_exists "$journal" && return 1
  done
  [[ ! -L "$node/backup-mounts" ]] || return 1
  for source in "$node/backup-mounts"/{root,logs,replays}; do
    [[ -f "$source" && ! -L "$source" ]] || return 1
  done
  IFS= read -r backup < "$node/backup-mounts/root" || return 1
  [[ -z "$requested" || "$requested" == "$backup" ]] || return 1
  [[ "$(find "$state" -maxdepth 0 -type d -uid 0 ! -perm /022 -print)" == "$state" ]] || return 1
  info=$(docker inspect --format '{{println .Image}}{{range .Mounts}}{{if eq .Type "bind"}}{{println .Destination .Source}}{{end}}{{end}}' "$cid") || return 1
  [[ "${info%%$'\n'*}" == "sha256:${release##*/}" ]] || return 1
  for part in config state management backup; do
    source="$state/$part"
    [[ "$part" != backup ]] || source=$backup
    [[ -d "$source" && "$(readlink -e -- "$source")" == "$source" ]] || return 1
    grep -Fxq -- "/data/jdmc/$part $source" <<< "$info" || return 1
  done
  printf '%s\n' "$backup"
}

function jdmc_migrate_and_start() (
  local node=$1 dir=$2 state=$3 live=$4 backup_override=$5
  shift 5
  local id="sha256:${dir##*/}" layout="$dir/jdmc-layout.py"
  local work storage_backup unit
  grep -Fq '/data/jdmc/state' "$dir/compose.yml" || { log_error "The selected JDMC image does not declare the required /data/jdmc/state volume"; return 1; }
  work=$(mktemp -d "$node/.layout-run.XXXXXX") || return 1
  trap 'rm -rf -- "$work"' EXIT
  storage_backup=$(python3 "$layout" plan "$state" "$work" "$node" \
    "$(get_config_or_env VOLUME_DIR /data/jumpserver)" "$backup_override" "$live" "$id") || return 1
  # Validate the target on this host while the native service can still serve.
  jdmc_compose "$node" "$dir" "$storage_backup" config --quiet || return 1
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
  python3 "$layout" apply "$state" "$work" "$id" "$live" || return 1
  jdmc_compose "$node" "$dir" "$storage_backup" "$@" || return 1
  local unshare socket
  unshare="$(get_config_or_env VOLUME_DIR /data/jumpserver)/core/data/unshare"
  for socket in "$unshare"/jdmc.sock{,.*} "$unshare"/kotl.sock{,.*}; do
    [[ ! -S "$socket" || -L "$socket" ]] || rm -- "$socket" || return 1
  done
  remove_config JDMC_SOCK_PATH || return 1
  cleanup_jdmc_legacy_switches || return 1
  ln -sfnT "$dir" "$node/.next-release" && mv -fT "$node/.next-release" "$node/release" || return 1
  python3 "$layout" commit "$state" "$work" "$node"
)

function container_jdmc_action() (
  set -eo pipefail
  local operation=$1 node image id dir state live storage_backup backup_override
  local -a up=(up -d --wait)
  state=$(get_current_jdmc_data_dir) || return 1
  node="$state/.installer"
  case "$operation" in
    ps|logs) ;;
    deploy|start|restart|stop|down)
      # Install configuration may have selected a different VOLUME_DIR.
      if [[ "$operation" == deploy ]]; then check_jdmc_deployment || return 1; fi
      # The project is host-wide. Keep the lock stable across VOLUME_DIR changes.
      umask 077
      exec 8>>/run/jumpserver-jdmc.lock || return 1
      flock -x 8 || return 1 ;;
    *) log_error "Unknown JDMC action: $operation"; return 2 ;;
  esac
  live=$(jdmc_container_id "$state") || return 1
  case "$operation" in
    ps|logs|stop)
      [[ -n "$live" ]] || return 0
      case "$operation" in
        ps) docker ps -a --filter "id=$live" ;;
        logs) docker logs --tail 100 -f "$live" ;;
        stop) docker stop "$live" ;;
      esac
      return ;;
    down)
      if [[ -n "$live" ]]; then docker stop "$live" && docker rm "$live" || return 1; fi
      remove_container_jdmc_integration
      return ;;
  esac
  if ! configure_container_jdmc "$live"; then
    # An unhealthy Core identity cannot prevent access to the host recovery UI.
    # Keep this mount separate so the next successful preparation can atomically
    # install the real keys without treating an empty directory as an identity.
    [[ -d "$node" && ! -L "$node" && "$(stat -c '%u:%a' "$node")" == 0:700 ]] || return 1
    export JDMC_OFFLINE_IDENTITY="$node/offline"
    install -d -o 0 -g 0 -m 0700 "$JDMC_OFFLINE_IDENTITY" "$JDMC_OFFLINE_IDENTITY"/{tls,core} || return 1
    log_warn "Core identity unavailable; starting JDMC with host PAM. Restore the node credentials and run jmsctl start jdmc."
  fi
  image=$(get_jdmc_image)
  id=$(docker image inspect --format '{{.Id}}' "$image") || return 1
  [[ "$id" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
  dir="$node/releases/${id#sha256:}"
  install -d -m 0700 "$node/releases" || return 1
  jdmc_extract_release "$id" "$dir" || return 1
  backup_override=$(get_config_or_env JDMC_HOST_BACKUP_DIR)
  [[ "$operation" != restart ]] || up+=(--force-recreate)
  if [[ "$operation" == start || "$operation" == restart ]] && storage_backup=$(jdmc_current_backup "$node" "$dir" "$state" "$live" "$backup_override"); then
    jdmc_compose "$node" "$dir" "$storage_backup" "${up[@]}" || return 1
  else
    jdmc_migrate_and_start "$node" "$dir" "$state" "$live" "$backup_override" "${up[@]}" || return 1
  fi
)
