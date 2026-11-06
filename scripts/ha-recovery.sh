#!/usr/bin/env bash
# Task-owned cold recovery. JSON is parsed with jq; no Python runtime is needed.
# State lives outside business storage. Never infer recovery from SDK results.
# jq expressions are intentionally single quoted; A && B || fail checks both.
# mkdir parents inherit the operation's 077 umask.
# shellcheck disable=SC2016,SC2015,SC2174
set -Eeuo pipefail
set +x
export LC_ALL=C
ROOT=/data/ha-toolkit/recovery
ACTIVE=/data/ha-toolkit/recovery-active.json
INFRA='["postgresql","redis","minio","es","loki"]'
PLAN='' RECEIPT='' CONFIG='' ROWS='' PATHS='' IMAGES='' DATABASE_PATHS='[]' DATABASE_LAYOUT='{}' PRESERVED_PATHS='[]'
TASK='' INSTALLER='' DIRECTORY='' OPERATION=build PURPOSE=startup ISOLATED=false

fail() {
    trap - ERR
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg error "$1" '{success:false,error:$error}' >&2
    else
        printf '%s\n' '{"success":false,"error":"missing recovery dependency: jq"}' >&2
    fi
    exit 1
}
# Do not expose command arguments, configuration or stderr containing secrets.
trap 'fail "recovery command failed at line $LINENO"' ERR
j() { jq "$@" 2>/dev/null; }
normalize_compose_ulimits() {
    # Some Compose builds render `core: 0` as `{}` in JSON, which they cannot parse again.
    j -c '(.services[].ulimits.core | select(. == {})) = 0'
}
require() { command -v "$1" >/dev/null 2>&1 || fail "missing recovery dependency: $1"; }
check_jq() {
    # Keep the jq 1.5 baseline, including builds without Oniguruma. Probe
    # capabilities rather than parsing vendor-specific version suffixes.
    require jq
    j -en --argjson sample '{"name":"/core","running":false}' '
      ($sample|with_entries(.value=.value)) as $copy |
      ($copy.name|ltrimstr("/"))=="core" and $copy.running==false and
      any([1,2][]; .==2) and all([1,2][]; .>0) and
      ("a\u0000b"|explode|index(0))==1 and
      ({a:1}|map_values(.+1)|.a)==2' >/dev/null ||
        fail 'incompatible jq: recovery requires jq 1.5-compatible JSON operations'
}
valid_task() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }

run() {
    local seconds=$1 status diagnostic='' error_file='' operation='' arg
    shift
    # GNU timeout owns the process group; kill descendants as well as the
    # parent so timed-out rsync cannot continue after a retry starts.
    if [[ "${1##*/}" == docker ]]; then
        case "${2:-}" in
            compose) for arg in "$@"; do case "$arg" in config|create|up|stop) operation="compose $arg";; esac; done ;;
            image) case "${3:-}" in load|save|inspect|ls|rm) operation="image $3";; esac ;;
            update|stop|tag|inspect|ps) operation=$2 ;;
        esac
        error_file=$(mktemp) || fail 'cannot create recovery diagnostic file'
        if env -u SHELLOPTS timeout --signal=KILL "$seconds" "$@" 2>"$error_file"; then
            rm -f -- "$error_file"
            return
        else status=$?; fi
        # Only expose a fixed, non-sensitive Compose schema error. Other
        # diagnostics can contain configuration, credentials or command args.
        if LC_ALL=C grep -Eq 'services\.[A-Za-z0-9_-]+\.ulimits\.core must be (an integer or string|a number or a string)' "$error_file"; then
            diagnostic=': invalid services.*.ulimits.core in Compose configuration'
        elif LC_ALL=C grep -Fqi 'cannot allocate memory' "$error_file"; then
            diagnostic=': system memory allocation failed'
        elif LC_ALL=C grep -Fqi 'no space left on device' "$error_file"; then
            diagnostic=': no space left on device'
        fi
        rm -f -- "$error_file"
        fail "docker ${operation:-operation} failed (exit $status)$diagnostic"
    fi
    if env -u SHELLOPTS timeout --signal=KILL "$seconds" "$@" 2>/dev/null; then return; else status=$?; fi
    fail "${1##*/} failed (exit $status)"
}
run_quiet() { run "$@" >/dev/null; }
valid_digest() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
digest() {
    local checksum
    checksum=$(sha256sum < "$1") || fail 'recovery file checksum failed'
    checksum=${checksum%% *}
    valid_digest "$checksum" || fail 'invalid recovery file checksum'
    printf '%s\n' "$checksum"
}
verify_checksum() {
    local algorithm=$1 path=$2 expected=$3 message=$4 actual
    valid_digest "$expected" || fail "$message"
    actual=$("$algorithm" "$path") || fail "$message"
    valid_digest "$actual" && [[ "$actual" == "$expected" ]] || fail "$message"
}

private_directory() {
    local path=$1 owner mode
    [[ -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] || fail 'unsafe recovery directory'
    read -r owner mode <<< "$(stat -c '%u %a' -- "$path")"
    [[ "$owner" == "$EUID" ]] && (( (8#$mode & 077) == 0 )) || fail 'unsafe recovery directory permissions'
}
read_json() {
    local path=$1 owner mode fd before after pid=${BASHPID:-$$}
    [[ -f "$path" && ! -L "$path" ]] || fail 'unsafe recovery state permissions'
    before=$(stat -c '%d:%i' -- "$path")
    exec {fd}<"$path"
    after=$(stat -Lc '%d:%i' -- "/proc/$pid/fd/$fd")
    # The containing state directory is private. Check the opened inode too,
    # rather than trusting only the pathname checked before open.
    [[ "$before" == "$after" && ! -L "$path" && -f "/proc/$pid/fd/$fd" ]] || fail 'unsafe recovery state permissions'
    read -r owner mode <<< "$(stat -Lc '%u %a' -- "/proc/$pid/fd/$fd")"
    [[ "$owner" == "$EUID" ]] && (( (8#$mode & 077) == 0 )) || fail 'unsafe recovery state permissions'
    j -ce -s 'if length == 1 and (.[0]|type)=="object" then .[0] else error("invalid state") end' <&"$fd"
    exec {fd}<&-
}
atomic() {
    local path=$1 value=$2 temporary owner mode
    mkdir -p -m 700 -- "${path%/*}"
    [[ ! -L "${path%/*}" && "$(realpath -e -- "${path%/*}")" == "${path%/*}" ]] || fail 'unsafe recovery state directory'
    read -r owner mode <<< "$(stat -c '%u %a' -- "${path%/*}")"
    [[ "$owner" == "$EUID" ]] && (( (8#$mode & 022)==0 )) || fail 'unsafe recovery state directory permissions'
    temporary=$(mktemp "${path%/*}/.${path##*/}-XXXXXX")
    chmod 600 "$temporary"
    if ! j -ceS -s 'if length==1 and (.[0]|type)=="object" then .[0] else error("invalid state") end' <<< "$value" > "$temporary"; then
        rm -f -- "$temporary"
        fail 'invalid recovery state'
    fi
    sync -f "$temporary"
    mv -fT -- "$temporary" "$path"
    sync -f "${path%/*}"
}
save_plan() { atomic "$DIRECTORY/manifest.json" "$PLAN"; }
set_phase() {
    atomic "$ACTIVE" "$(j -cn --arg task "$TASK" --arg directory "$DIRECTORY" --arg phase "$1" '{task_id:$task,directory:$directory,phase:$phase}')"
}
clear_active() {
    if [[ -e "$ACTIVE" || -L "$ACTIVE" ]]; then
        local receipt
        receipt=$(read_json "$ACTIVE")
        if [[ "$(j -r .task_id <<< "$receipt")" == "$TASK" ]]; then
            rm -- "$ACTIVE"
            sync -f "${ACTIVE%/*}"
        fi
    fi
}

# Match Python's version-1 tree digest, including metadata, Unicode escaping,
# symlink targets and walk order, so existing recovery snapshots remain valid.
python_array() {
    local data=$1 parts item separator=
    parts=$(j -ac '.[]' <<< "$data") || fail 'invalid recovery tree entry'
    printf '[' || return 1
    while IFS= read -r item; do printf '%s%s' "$separator" "$item" || return 1; separator=', '; done <<< "$parts"
    printf ']'
}
tree_item() {
    local root=$1 path=$2 relative=$3 mode uid gid item extra metadata checksum
    metadata=$(stat -c '%f %u %g' -- "$path") || fail 'recovery tree metadata read failed'
    read -r mode uid gid <<< "$metadata" || fail 'invalid recovery tree metadata'
    mode=$((16#$mode))
    item=$(j -cn --arg name "$relative" --argjson mode "$mode" --argjson uid "$uid" --argjson gid "$gid" '[$name,$mode,$uid,$gid]') || fail 'invalid recovery tree entry'
    if [[ -L "$path" ]]; then
        # Preserve trailing newlines in a symlink target via a sentinel.
        extra=$(readlink -n -- "$path" || exit 1; printf '.') || fail 'recovery symlink read failed'
        extra=${extra%.}
        item=$(j -c --arg value "$extra" '.+[$value]' <<< "$item") || fail 'invalid recovery symlink entry'
    elif [[ -f "$path" ]]; then
        checksum=$(digest "$path") || fail 'recovery tree file checksum failed'
        valid_digest "$checksum" || fail 'invalid recovery tree file checksum'
        item=$(j -c --arg value "$checksum" '.+[$value]' <<< "$item") || fail 'invalid recovery tree file entry'
    elif [[ ! -d "$path" ]]; then
        [[ -S "$path" ]] && return 0
        fail 'unsupported special file in recovery storage'
    fi
    python_array "$item" || fail 'recovery tree serialization failed'
    [[ "$relative" == . ]] || printf '\n'
}
tree_walk() {
    local root=$1 directory=$2 path list
    local -a entries=()
    # NUL separators preserve spaces/newlines in filenames; pipefail ensures
    # failed traversal never silently produces a valid incomplete checksum.
    list=$(mktemp) || fail 'recovery tree inventory creation failed'
    if ! find "$directory" -mindepth 1 -maxdepth 1 -print0 | sort -z > "$list"; then
        rm -f -- "$list"
        fail 'recovery tree traversal failed'
    fi
    while IFS= read -r -d '' path; do entries+=("$path"); done < "$list" || fail 'recovery tree inventory read failed'
    rm -f -- "$list" || fail 'recovery tree inventory cleanup failed'
    for path in "${entries[@]}"; do tree_item "$root" "$path" "${path#"$root"/}" || return 1; done
    for path in "${entries[@]}"; do
        if [[ -d "$path" && ! -L "$path" ]]; then tree_walk "$root" "$path" || return 1; fi
    done
}
tree_digest() {
    local checksum
    checksum=$({ tree_item "$1" "$1" . || exit 1; tree_walk "$1" "$1" || exit 1; } | sha256sum) || fail 'recovery tree checksum failed'
    checksum=${checksum%% *}
    valid_digest "$checksum" || fail 'invalid recovery tree checksum'
    printf '%s\n' "$checksum"
}
validate_destination() {
    local target=$1
    case "$target" in /|/opt|/opt/current|/home|/root|/data|/var|/usr|/etc) fail 'unsafe recovery destination';; esac
    [[ "$target" == /* && "$target" != *$'\n'* && "$(realpath -ms -- "$target")" == "$target" ]] || fail 'unsafe recovery destination'
    [[ "$target" != "$ROOT" && "$target" != "$ROOT/"* && "$ROOT" != "$target/"* ]] || fail 'recovery storage overlaps the deployment snapshot'
}
validate_plan() {
    j -e --arg task "$TASK" '.version==1 and .task_id==$task and (.paths|type)=="array"' <<< "$PLAN" >/dev/null || fail 'recovery task identity mismatch'
    verify_checksum digest "$DIRECTORY/compose.json" "$(j -r .compose_sha256 <<< "$PLAN")" 'original Compose configuration checksum mismatch'
    if j -e 'has("recovery_sha256")' <<< "$PLAN" >/dev/null; then
        [[ -f "$DIRECTORY/ha-recovery.sh" && ! -L "$DIRECTORY/ha-recovery.sh" ]] || fail 'task recovery executor is missing or unsafe'
        verify_checksum digest "$DIRECTORY/ha-recovery.sh" "$(j -r .recovery_sha256 <<< "$PLAN")" 'task recovery executor checksum mismatch'
    fi
    if j -e '.waf != null' <<< "$PLAN" >/dev/null; then
        verify_checksum digest "$DIRECTORY/waf-compose.json" "$(j -r .waf.sha256 <<< "$PLAN")" 'original NGSWAF configuration checksum mismatch'
    fi
    local targets target
    targets=$(j -c '.paths[]' <<< "$PLAN")
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        target=$(j -r . <<< "$target")
        j -e --arg target "$target" '(["/data/jumpserver","/data/ngswaf","/opt/jumpserver/config"]+(.deployment_roots//[])+(.database_paths//[]))|index($target)!=null' <<< "$PLAN" >/dev/null || fail 'unsupported recovery destination'
        validate_destination "$target"
    done <<< "$targets"
}
local_image_entries() {
    j -e '.images as $images |
      ($images|type)=="array" and ($images|length)>0 and (.image_tags|type)=="object" and
      ($images|sort)==(.image_tags|keys) and
      ($images|sort)==([.containers[].image,(.waf_containers//{})[].image]|unique)' <<< "$PLAN" >/dev/null ||
        fail 'invalid local recovery image inventory'
    local entries entry image tag
    entries=$(j -c '.image_tags|to_entries[]' <<< "$PLAN")
    while IFS= read -r entry; do
        image=$(j -er .key <<< "$entry")
        tag=$(j -er .value <<< "$entry")
        [[ "$image" == sha256:* ]] && valid_digest "${image#sha256:}" || fail 'invalid recovery image identity'
        [[ "$tag" == "jdmc-ha-recovery/$TASK:${image#sha256:}" ]] || fail 'invalid recovery image retention tag'
    done <<< "$entries"
    printf '%s\n' "$entries"
}
verify_local_images() {
    local entries entry image actual tag
    entries=$(local_image_entries)
    while IFS= read -r entry; do
        image=$(j -r .key <<< "$entry")
        tag=$(j -r .value <<< "$entry")
        actual=$(run 60 docker image inspect -f '{{.Id}}' "$tag")
        [[ "$actual" == "$image" ]] || fail 'local recovery image retention tag changed'
    done <<< "$entries"
}
protect_images() {
    [[ "$(j -r '.image_backup_mode//"archive"' <<< "$PLAN")" == local ]] || return 0
    local entries entry
    entries=$(local_image_entries)
    # Independent references preserve the original layers when an installer
    # overwrites business tags. They do not protect against prune -a or loss
    # of Docker storage; task-controlled workflows must never prune images.
    while IFS= read -r entry; do
        run_quiet 60 docker tag "$(j -r .key <<< "$entry")" "$(j -r .value <<< "$entry")"
    done <<< "$entries"
    verify_local_images
}
cleanup_images() {
    [[ "$(j -r '.image_backup_mode//"archive"' <<< "$PLAN")" == local ]] || return 0
    j -e '.completed==true' <<< "$PLAN" >/dev/null || fail 'image cleanup requires completed business recovery'
    if j -e '.images_released==true' <<< "$PLAN" >/dev/null; then return; fi
    local entries entry image tag actual present
    entries=$(local_image_entries)
    present=$(run 60 docker image ls --format '{{.Repository}}:{{.Tag}}' "jdmc-ha-recovery/$TASK" | j -Rsc 'split("\n")|map(select(length>0))')
    while IFS= read -r entry; do
        image=$(j -r .key <<< "$entry")
        tag=$(j -r .value <<< "$entry")
        if ! j -e --arg tag "$tag" 'index($tag)!=null' <<< "$present" >/dev/null; then continue; fi
        actual=$(run 60 docker image inspect -f '{{.Id}}' "$tag")
        [[ "$actual" == "$image" ]] || fail 'local recovery image retention tag changed'
        # Remove this task's reference only, never force-delete a shared ID.
        run_quiet 60 docker image rm "$tag"
    done <<< "$entries"
    PLAN=$(j -c '.images_released=true' <<< "$PLAN")
    save_plan
}
verify_snapshot() {
    j -e '.captured==true and (.paths|type)=="array" and (.paths|length)>0 and
      (.files_sha256|type)=="array" and all(.files_sha256[]; type=="string" and length==64) and
      (.files_sha256|length)==(.paths|length)' <<< "$PLAN" >/dev/null || fail 'complete recovery point is unavailable or inventory mismatches'
    case "$(j -r '.image_backup_mode//"archive"' <<< "$PLAN")" in
        local) verify_local_images;;
        archive) verify_checksum digest "$DIRECTORY/images.tar" "$(j -r .images_sha256 <<< "$PLAN")" 'recovery image archive checksum mismatch';;
        *) fail 'unsupported recovery image backup mode';;
    esac
    if j -e 'has("entrypoints_sha256")' <<< "$PLAN" >/dev/null; then
        [[ -d "$DIRECTORY/entrypoints" && ! -L "$DIRECTORY/entrypoints" ]] || fail 'recovery entrypoint snapshot is missing or unsafe'
        verify_checksum tree_digest "$DIRECTORY/entrypoints" "$(j -r .entrypoints_sha256 <<< "$PLAN")" 'recovery entrypoint snapshot checksum mismatch'
    fi
    local checks expected index=0 source
    checks=$(j -r '.files_sha256[]' <<< "$PLAN")
    while IFS= read -r expected; do
        valid_digest "$expected" || fail 'invalid recovery file snapshot checksum'
        source="$DIRECTORY/files/$index"
        [[ -d "$source" && ! -L "$source" ]] || fail 'recovery file snapshot is missing or unsafe'
        verify_checksum tree_digest "$source" "$expected" 'recovery file snapshot checksum mismatch'
        index=$((index+1))
    done <<< "$checks"
}
compose() {
    local item=$1 project path
    shift
    project=$(j -er .project <<< "$item")
    path=$(j -er .compose_path <<< "$item")
    # Recovery can restart many containers on a host with fragmented memory.
    # Serialize Docker operations instead of creating all veth pairs at once.
    run_quiet 600 docker compose --parallel 1 -p "$project" -f "$path" "$@"
}
inspect() { if (($#)); then run 600 docker inspect "$@"; else printf '[]\n'; fi; }
# Convert validated JSON strings to a bash array without eval or word splitting.
json_args() {
    local data=$1 value entries
    ARGS=()
    entries=$(j -c '.[]' <<< "$data")
    while IFS= read -r value; do
        [[ -n "$value" ]] || continue
        value=$(j -er 'if type=="string" and length>0 and (explode|index(0)==null) then . else error("invalid argument") end' <<< "$value")
        ARGS+=("$value")
    done <<< "$entries"
}
runtime_mount() {
    local service=$1 source=$2 target=$3
    if [[ "$source" == /dev/bus/usb && "$target" == "$source" && ( "$service" == core || "$service" == celery ) ]]; then return 0; fi
    if [[ "$source" == /sys/fs/bpf && "$target" == "$source" && "$service" == web ]]; then
        if ! env -u SHELLOPTS timeout --signal=KILL 600 systemctl is-active --quiet sangfor-zta 2>/dev/null; then
            fail 'ZTA must be running for the web BPF runtime mount'
        fi
        return 0
    fi
    return 1
}
inside_roots() { j -e --arg source "$1" 'any(.[]; . as $root | $source==$root or ($source|startswith($root+"/")))' <<< "$2" >/dev/null; }
validate_database_storage() {
    local service=$1 row=$2 name path
    name=$(j -r '.Name|ltrimstr("/")' <<< "$row")
    if [[ "$service" == postgresql ]]; then
        path=$(run 30 docker exec "$name" sh -c 'exec psql -X -w -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -Atc "SHOW data_directory"')
    else
        path=$(run 30 docker exec "$name" sh -c 'export REDISCLI_AUTH="$REDIS_PASSWORD"; exec redis-cli --raw --no-auth-warning -p "${REDIS_PORT:-6379}" CONFIG GET dir')
        [[ "$path" == $'dir\n'/* ]] || fail 'Redis data directory could not be inspected'
        path=${path#*$'\n'}
    fi
    [[ "$path" == /* && "$path" != *$'\n'* ]] || fail 'invalid database data directory'
    path=$(run 30 docker exec "$name" readlink -e -- "$path")
    j -e --arg path "$path" '.Mounts | any(.[]; .Type=="bind" and .RW and (.Destination as $root | $path==$root or ($path|startswith($root+"/"))))' <<< "$row" >/dev/null || fail 'database data directory is not on persistent bind storage'
    DATABASE_LAYOUT=$(j -c --arg service "$service" --arg path "$path" '.[$service]=$path' <<< "$DATABASE_LAYOUT")
}
validate_inventory() {
    local config=$1 rows=$2
    printf '%s\n' "$config" "$rows" | j -es '
      .[0] as $config | .[1] as $rows |
      [$config.services[].container_name] as $names |
      ($names|length)==($names|unique|length) and
      ($names|sort)==([$rows[].Name|ltrimstr("/")]|sort)' >/dev/null || fail 'container inventory does not match Compose configuration'
}
inventory() {
    CONFIG=$(run 600 bash "$INSTALLER" raw config --format json)
    j -e '.services | has("postgresql") and has("redis") and has("core")' <<< "$CONFIG" >/dev/null || fail 'automatic recovery requires local PostgreSQL and Redis'
    j -e 'all(.services[]; (.container_name|type)=="string" and (.container_name|length)>0 and (.image|type)=="string" and (.image|length)>0)' <<< "$CONFIG" >/dev/null || fail 'automatic recovery requires explicit container and image identities'
    json_args "$(j -c '[.services[].container_name]' <<< "$CONFIG")"
    ROWS=$(inspect "${ARGS[@]}")
    validate_inventory "$CONFIG" "$ROWS"
    local running row entries mount mounts source service storage
    DATABASE_PATHS='[]'
    DATABASE_LAYOUT='{}'
    PRESERVED_PATHS='[]'
    storage=$(j -cn --arg root "$(realpath -e /data/jumpserver)" '[$root,"/opt/jumpserver/config"]')
    running=$(run 600 docker ps --filter 'name=^jms_' --format '{{.Names}}')
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        j -e --arg name "$row" 'any(.services[]; .container_name==$name)' <<< "$CONFIG" >/dev/null || fail 'unmanaged JMS containers prevent consistent recovery'
    done <<< "$running"
    entries=$(j -c '.[]' <<< "$ROWS")
    while IFS= read -r row; do
        j -e '.HostConfig.NetworkMode!="host"' <<< "$row" >/dev/null || fail 'host-network business containers require a dedicated recovery adapter'
        service=$(j -er --arg name "$(j -r '.Name|ltrimstr("/")' <<< "$row")" '.services|to_entries[]|select(.value.container_name==$name)|.key' <<< "$CONFIG")
        if [[ "$service" == postgresql || "$service" == redis ]]; then validate_database_storage "$service" "$row"; fi
        mounts=$(j -c '.Mounts[]|select(.RW)' <<< "$row")
        while IFS= read -r mount; do
            [[ -n "$mount" ]] || continue
            source=$(realpath -m -- "$(j -er .Source <<< "$mount")")
            if [[ "$(j -r .Type <<< "$mount")" == bind ]] && runtime_mount "$service" "$source" "$(j -r .Destination <<< "$mount")"; then continue; fi
            [[ "$(j -r .Type <<< "$mount")" == bind ]] && inside_roots "$source" "$storage" || fail 'business storage outside managed recovery roots'
            if [[ "$service" == postgresql || "$service" == redis ]]; then
                if inside_roots "$source" '["/opt/jumpserver/config"]'; then continue; fi
                [[ -d "$source" && "$source" != "$(realpath -e /data/jumpserver)" ]] || fail 'database requires a dedicated data directory'
                DATABASE_PATHS=$(j -c --arg path "$source" '.+[$path]|unique' <<< "$DATABASE_PATHS")
            else
                PRESERVED_PATHS=$(j -c --arg path "$source" '.+[$path]|unique' <<< "$PRESERVED_PATHS")
            fi
        done <<< "$mounts"
    done <<< "$entries"
}
check() {
    local capabilities program installer_root path paths size=0 amount required free image actual waf_config waf_rows mounts mount source
    capabilities=$(run 600 bash "$INSTALLER" recovery_capabilities)
    j -e '.version==1 and .full_table_data==true and .restore_data_only==true' <<< "$capabilities" >/dev/null || fail 'installer does not support coordinated full recovery'
    j -e '.coordinated_startup==1' <<< "$capabilities" >/dev/null || fail 'coordinated startup isolation is required before automatic recovery can be enabled'
    for program in docker rsync du flock jq timeout realpath sha256sum stat find sort sync; do require "$program"; done
    check_jdmc_socket
    inventory
    CONFIG=$(normalize_compose_ulimits <<< "$CONFIG")
    run_quiet 600 docker compose -f - config --quiet <<< "$CONFIG"
    installer_root=$(dirname -- "$(realpath -e -- "$INSTALLER")")
    [[ "$(j 'length' <<< "$DATABASE_PATHS")" -ge 2 ]] || fail 'PostgreSQL and Redis require persistent data directories'
    if [[ "${HA_RECOVERY_LEGACY:-0}" == 1 ]]; then
        PATHS=$(j -cn --arg root "$installer_root" '["/data/jumpserver","/opt/jumpserver/config",$root]')
    else
        PATHS=$(j -cn --arg root "$installer_root" --argjson databases "$DATABASE_PATHS" '$databases+["/opt/jumpserver/config",$root]')
    fi
    if [[ -e /data/ngswaf ]]; then PATHS=$(j -c '.+["/data/ngswaf"]' <<< "$PATHS"); fi
    if [[ -L /opt/current/osm ]]; then
        capabilities=$(run 600 bash /opt/current/osm/osmctl.sh recovery-capabilities)
        j -e '.coordinated_startup==1' <<< "$capabilities" >/dev/null || fail 'OSM coordinated startup isolation is required'
        PATHS=$(j -c --arg root "$(realpath -e /opt/current/osm)" '.+[$root]' <<< "$PATHS")
    fi
    PATHS=$(j -c 'unique as $paths | [$paths[] | . as $path | select(any($paths[]; . as $parent | $parent!=$path and ($path|startswith($parent+"/")))|not)]' <<< "$PATHS")
    # A broad deployment mount must not accidentally capture recordings again.
    source=$(realpath -e /data/jumpserver)
    if [[ "${HA_RECOVERY_LEGACY:-0}" != 1 ]]; then
        inside_roots "$source" "$PATHS" && fail 'recovery roots must not include the complete business data directory'
    fi
    paths=$(j -c '.[]' <<< "$PATHS")
    while IFS= read -r path; do
        path=$(j -r . <<< "$path")
        [[ -d "$path" && "$(realpath -e -- "$path")" == "$path" ]] || fail 'symlinked or missing recovery root needs an explicit adapter'
        validate_destination "$path"
        amount=$(run 600 du -sb -- "$path"); amount=${amount%%$'\t'*}
        [[ "$amount" =~ ^[0-9]+$ ]] || fail 'invalid recovery storage size'
        size=$((size+amount))
    done <<< "$paths"
    IMAGES=$(j -c '[.[].Image]|unique' <<< "$ROWS")
    if [[ -f /opt/current/osm/ngswaf/ngswafctl.sh ]]; then
        capabilities=$(run 600 bash /opt/current/osm/ngswaf/ngswafctl.sh recovery-capabilities)
        j -e '.coordinated_startup==1' <<< "$capabilities" >/dev/null || fail 'NGSWAF coordinated startup isolation is required'
        waf_config=$(run 600 env -u COMPOSE_PROJECT_NAME bash /opt/current/osm/ngswaf/ngswafctl.sh recovery-config)
        waf_config=$(normalize_compose_ulimits <<< "$waf_config")
        run_quiet 600 docker compose -f - config --quiet <<< "$waf_config"
        json_args "$(j -c '[.services[].container_name]' <<< "$waf_config")"
        waf_rows=$(inspect "${ARGS[@]}")
        validate_inventory "$waf_config" "$waf_rows"
        mounts=$(j -c '.[].Mounts[]|select(.RW)' <<< "$waf_rows")
        while IFS= read -r mount; do
            [[ -n "$mount" ]] || continue
            source=$(realpath -m -- "$(j -er .Source <<< "$mount")")
            inside_roots "$source" "$PATHS" || fail 'NGSWAF storage outside managed recovery roots'
        done <<< "$mounts"
        IMAGES=$(printf '%s\n' "$IMAGES" "$waf_rows" | j -cs '.[0]+[.[1][].Image]|unique')
    fi
    json_args "$IMAGES"
    for image in "${ARGS[@]}"; do
        actual=$(run 60 docker image inspect -f '{{.Id}}' "$image")
        [[ "$actual" == "$image" ]] || fail 'original recovery image is unavailable'
    done
    required=$((size*2+5*1024*1024*1024))
    free=$(df -B1 --output=avail -- "$DIRECTORY" | tail -n 1); free=${free// /}
    [[ "$free" =~ ^[0-9]+$ ]] || fail 'invalid available recovery storage'
    (( free >= required )) || fail "insufficient recovery storage: at least $required bytes required"
}

stop_databases() {
    local service name row value
    for service in redis postgresql; do
        name=$(j -er --arg service "$service" '.services[$service]' <<< "$PLAN")
        row=$(inspect "$name")
        if j -e '.[0].State.Running' <<< "$row" >/dev/null; then
            run_quiet 600 docker update --restart=no "$name"
            if [[ "$service" == redis ]]; then
                # SAVE also covers instances with periodic snapshots disabled.
                # Read auth inside the container; never expose it in argv/logs.
                value=$(run 600 docker exec "$name" sh -c 'export REDISCLI_AUTH="$REDIS_PASSWORD"; exec redis-cli --raw --no-auth-warning -p "${REDIS_PORT:-6379}" SAVE')
                [[ "$value" == OK ]] || fail 'Redis persistence failed before cold backup'
            fi
            # Do not let Docker turn a slow clean shutdown into SIGKILL.
            run_quiet 600 docker stop --time -1 "$name"
        fi
        row=$(inspect "$name")
        j -e 'length==1 and all(.[]; .State.Running==false and .State.ExitCode==0 and .State.OOMKilled!=true)' <<< "$row" >/dev/null || fail 'database did not shut down cleanly'
    done
}
shutdown_proof() {
    local name image path output key value system='' timeline='' lsn='' state=''
    name=$(j -er '.services.postgresql' <<< "$PLAN")
    image=$(j -er --arg name "$name" '.containers[$name].image' <<< "$PLAN")
    path=$(j -er '.database_layout.postgresql' <<< "$PLAN")
    # Read the stopped instance using its original binary and read-only mounts.
    # The shutdown checkpoint includes WAL produced after the last SQL probe.
    output=$(run 60 docker run --rm --network none --read-only --env LC_ALL=C --volumes-from "$name:ro" --entrypoint pg_controldata "$image" "$path")
    while IFS=: read -r key value; do
        value=${value//[[:space:]]/}
        case "$key" in
            'Database system identifier') system=$value;;
            "Latest checkpoint's TimeLineID") timeline=$value;;
            'Latest checkpoint location') lsn=$value;;
            'Database cluster state') state=$value;;
        esac
    done <<< "$output"
    [[ "$system" =~ ^[0-9]+$ && "$timeline" =~ ^[0-9]+$ && "$lsn" =~ ^[0-9A-F]+/[0-9A-F]+$ ]] || fail 'invalid PostgreSQL shutdown checkpoint'
    [[ "$state" == shutdown || "$state" == shutdowninrecovery ]] || fail 'PostgreSQL control file does not confirm clean shutdown'
    j -cn --arg system "$system" --arg timeline "$timeline" --arg lsn "$lsn" --arg state "$state" '{system_id:$system,timeline:$timeline,lsn:$lsn,state:$state}'
}
validate_database_links() {
    local paths path link target list
    paths=$(j -r '.database_paths//[]|.[]' <<< "$PLAN")
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        list=$(mktemp)
        find "$path" -type l -print0 > "$list" || fail 'database symlink inventory failed'
        while IFS= read -r -d '' link; do
            target=$(realpath -e -- "$link") || fail 'database contains a broken storage link'
            inside_roots "$target" "$(j -c .database_paths <<< "$PLAN")" || fail 'external database WAL or tablespace requires an explicit recovery adapter'
        done < "$list"
        rm -f -- "$list"
    done <<< "$paths"
}
stop() {
    local infrastructure=${1:-true} present names projects project candidates rows name
    present=$(run 600 docker ps -a --format '{{.Names}}' | j -Rsc 'split("\n")|map(select(length>0))')
    names=$(printf '%s\n' "$PLAN" "$present" | j -cs --argjson infra "$INFRA" --argjson all "$infrastructure" '
      .[1] as $present | .[0] | [.services|to_entries[]|select($all or (.key as $s|$infra|index($s)==null))|.value] +
      [(.waf_containers//{})|keys[]] | map(select(. as $n|$present|index($n)!=null))')
    projects=$(j -r '[.project,.waf.project//empty]|.[]' <<< "$PLAN")
    while IFS= read -r project; do
        candidates=$(run 600 docker ps -a --filter "label=com.docker.compose.project=$project" --format '{{.Names}}' | j -Rsc 'split("\n")|map(select(length>0))')
        json_args "$candidates"
        rows=$(inspect "${ARGS[@]}")
        names=$(printf '%s\n' "$names" "$rows" | j -cs --argjson infra "$INFRA" --argjson all "$infrastructure" '.[0] as $names | .[1] as $rows | $names+[$rows[]|select($all or (.Config.Labels["com.docker.compose.service"] as $s|$infra|index($s)==null))|.Name|ltrimstr("/")]|unique')
    done <<< "$projects"
    json_args "$names"
    for name in "${ARGS[@]}"; do run_quiet 600 docker update --restart=no "$name"; done
    if ((${#ARGS[@]})); then run_quiet 600 docker stop --time 120 "${ARGS[@]}"; fi
    rows=$(inspect "${ARGS[@]}")
    j -e 'all(.[]; .State.Running==false)' <<< "$rows" >/dev/null || fail 'business containers are still running'
}
wait_healthy() {
    (($#)) || return 0
    local deadline=$((SECONDS+300)) stable=-1 rows
    while (( SECONDS < deadline )); do
        rows=$(inspect "$@")
        if j -e --argjson count "$#" 'length==$count and all(.[]; .State.Running==true and (.State.Health.Status//"healthy")=="healthy")' <<< "$rows" >/dev/null; then
            (( stable >= 0 )) || stable=$SECONDS
            if (( SECONDS-stable >= 10 )); then return; fi
        else stable=-1; fi
        sleep 5
    done
    fail 'containers did not remain healthy within 300 seconds'
}
pinned_config() {
    local config=$1
    printf '%s\n' "$config" "$PLAN" | j -cs '.[1] as $plan | .[0] | .services |= with_entries(.value.image=$plan.containers[$plan.services[.key]].image | .value.restart="no")' | normalize_compose_ulimits
}
compose_start() {
    local attempt diagnostic
    diagnostic=$(mktemp)
    for attempt in 1 2 3; do
        if (compose "$@") 2>"$diagnostic"; then
            rm -f -- "$diagnostic"
            return 0
        fi
        if (( attempt == 3 )) || ! grep -Fq 'system memory allocation failed' "$diagnostic"; then
            cat -- "$diagnostic" >&2
            rm -f -- "$diagnostic"
            return 1
        fi
        printf 'Retrying HA container startup after memory allocation failure (%s/3)\n' "$attempt" >&2
        sleep 5
    done
}
start_infrastructure() {
    local config target="$DIRECTORY/infrastructure-compose.json" item names
    config=$(read_json "$DIRECTORY/compose.json")
    config=$(pinned_config "$config")
    atomic "$target" "$config"
    item=$(j -c --arg target "$target" '{project:.project,compose_path:$target}' <<< "$PLAN")
    names=$(j -c --argjson infra "$INFRA" '[.services|keys[]|select(. as $s|$infra|index($s)!=null)]' <<< "$PLAN")
    json_args "$names"
    compose_start "$item" up -d --no-deps --no-recreate --pull never "${ARGS[@]}"
    names=$(printf '%s\n' "$PLAN" "$names" | j -cs '.[1] as $names | .[0] | [.services[$names[]]]')
    json_args "$names"
    wait_healthy "${ARGS[@]}"
}
container_states() {
    j -c 'map({key:(.Name|ltrimstr("/")),value:{running:.State.Running,image:.Image,reference:.Config.Image,restart:.HostConfig.RestartPolicy}})|from_entries' <<< "$1"
}
capture_entrypoints() {
    local path name
    [[ ! -L "$DIRECTORY/entrypoints" ]] || fail 'unsafe recovery entrypoint snapshot'
    mkdir -p -m 700 -- "$DIRECTORY/entrypoints"
    for path in /usr/bin/jmsctl /var/run/installer.lock /var/run/osm.lock; do
        name=${path##*/}
        if [[ -e "$DIRECTORY/entrypoints/$name" || -L "$DIRECTORY/entrypoints/$name" ]]; then
            [[ -f "$DIRECTORY/entrypoints/$name" || -L "$DIRECTORY/entrypoints/$name" ]] || fail 'unsafe recovery entrypoint snapshot'
            rm -- "$DIRECTORY/entrypoints/$name"
        fi
        if [[ -e "$path" || -L "$path" ]]; then
            [[ -f "$path" || -L "$path" ]] || fail 'unsupported recovery entrypoint'
            cp -aP -- "$path" "$DIRECTORY/entrypoints/$name"
        fi
    done
    PLAN=$(j -c --arg checksum "$(tree_digest "$DIRECTORY/entrypoints")" '.entrypoints_sha256=$checksum' <<< "$PLAN")
}
restore_entrypoints() {
    # These files can redirect later starts to the failed release even after
    # /opt/current was restored. Keep old recovery points backward compatible.
    j -e 'has("entrypoints_sha256")' <<< "$PLAN" >/dev/null || return 0
    local path source temporary
    for path in /usr/bin/jmsctl /var/run/installer.lock /var/run/osm.lock; do
        source="$DIRECTORY/entrypoints/${path##*/}"
        [[ ! -e "$path" || -f "$path" || -L "$path" ]] || fail 'recovery entrypoint was replaced by a directory'
        temporary="${path%/*}/.${path##*/}-$TASK"
        [[ ! -e "$temporary" && ! -L "$temporary" ]] || fail 'unexpected pending recovery entrypoint'
        if [[ -e "$source" || -L "$source" ]]; then
            [[ -f "$source" || -L "$source" ]] || fail 'unsupported recovery entrypoint snapshot'
            cp -aP -- "$source" "$temporary"
            mv -fT -- "$temporary" "$path"
        elif [[ -e "$path" || -L "$path" ]]; then
            rm -- "$path"
        fi
    done
}
freeze() {
    local original="$DIRECTORY/compose.json" deployment links link target waf_config waf_rows waf_path="$DIRECTORY/waf-compose.json"
    local checksum containers installer_path recovery_checksum temporary
    if [[ -e "$DIRECTORY/manifest.json" || -L "$DIRECTORY/manifest.json" ]]; then
        PLAN=$(read_json "$DIRECTORY/manifest.json")
        validate_plan
        [[ "$(j -r '.operation//"build"' <<< "$PLAN")" == "$OPERATION" ]] || fail 'recovery operation cannot change after freeze begins'
        if [[ "$ISOLATED" == true ]]; then
            j -e '.original_isolated==true' <<< "$PLAN" >/dev/null || fail 'initial node isolation cannot change after freeze begins'
        fi
        j -e '(.completed or .releasing or .restored)|not' <<< "$PLAN" >/dev/null || fail 'recovery has advanced beyond freeze'
    else
        check
        atomic "$original" "$CONFIG"
        deployment=$(j -cn --arg root "$(dirname -- "$(realpath -e -- "$INSTALLER")")" '[$root]')
        if [[ -L /opt/current/osm ]]; then deployment=$(j -c --arg root "$(realpath -e /opt/current/osm)" '.+[$root]' <<< "$deployment"); fi
        links='{}'
        for link in /opt/current/installer /opt/current/osm; do
            if [[ -L "$link" ]]; then
                target=$(readlink -- "$link")
                links=$(j -c --arg link "$link" --arg target "$target" '.[$link]=$target' <<< "$links")
            fi
        done
        checksum=$(digest "$original") || fail 'original Compose checksum failed'
        valid_digest "$checksum" || fail 'invalid original Compose checksum'
        containers=$(container_states "$ROWS")
        installer_path=$(realpath -e -- "$INSTALLER")
        temporary=$(mktemp "$DIRECTORY/.recovery-XXXXXX")
        cp -- "${BASH_SOURCE[0]}" "$temporary"
        chmod 600 "$temporary"
        sync -f "$temporary"
        mv -fT -- "$temporary" "$DIRECTORY/ha-recovery.sh"
        recovery_checksum=$(digest "$DIRECTORY/ha-recovery.sh")
        PLAN=$(printf '%s\n' "$CONFIG" "$containers" "$PATHS" "$IMAGES" "$deployment" "$links" | \
            j -cs --arg task "$TASK" --arg operation "$OPERATION" --arg original "$original" \
            --arg installer "$installer_path" --arg recovery "$recovery_checksum" --arg license_socket "${JDMC_LICENSE_SOCKET:-/data/jumpserver/core/data/unshare/jdmc.sock}" --arg checksum "$checksum" --argjson isolated "$ISOLATED" \
            --argjson databases "$DATABASE_PATHS" --argjson layout "$DATABASE_LAYOUT" --argjson preserved "$PRESERVED_PATHS" '
            .[0] as $config | .[1] as $containers | .[2] as $paths | .[3] as $images | .[4] as $roots | .[5] as $links |
            {version:1,task_id:$task,project:($config.name//"jms"),operation:$operation,compose_path:$original,
             services:($config.services|map_values(.container_name)),containers:$containers,paths:$paths,images:$images,
             captured:false,restored:false,original_isolated:$isolated,deployment_roots:$roots,completed:false,
             storage_scope:"databases",database_paths:$databases,database_layout:$layout,preserved_paths:$preserved,
             installer:$installer,recovery_sha256:$recovery,license_socket:$license_socket,compose_sha256:$checksum,links:$links}')
        if [[ "${HA_RECOVERY_LEGACY:-0}" == 1 ]]; then
            PLAN=$(j -c 'del(.storage_scope,.database_paths,.database_layout,.preserved_paths)' <<< "$PLAN")
        fi
        if [[ -f /opt/current/osm/ngswaf/ngswafctl.sh ]]; then
            waf_config=$(run 600 env -u COMPOSE_PROJECT_NAME bash /opt/current/osm/ngswaf/ngswafctl.sh recovery-config)
            waf_config=$(normalize_compose_ulimits <<< "$waf_config")
            atomic "$waf_path" "$waf_config"
            json_args "$(j -c '[.services[].container_name]' <<< "$waf_config")"
            waf_rows=$(inspect "${ARGS[@]}")
            checksum=$(digest "$waf_path") || fail 'original NGSWAF checksum failed'
            valid_digest "$checksum" || fail 'invalid original NGSWAF checksum'
            containers=$(container_states "$waf_rows")
            PLAN=$(printf '%s\n' "$PLAN" "$waf_config" "$waf_rows" "$containers" | \
                j -cs --arg path "$waf_path" --arg checksum "$checksum" '
                .[1] as $config | .[2] as $rows | .[3] as $containers | .[0] |
                .waf={project:($config.name//"ngswaf"),compose_path:$path,sha256:$checksum,services:($config.services|map_values(.container_name))} |
                .waf_images=($rows|map({key:(.Name|ltrimstr("/")),value:.Image})|from_entries) |
                .waf_containers=$containers | .images=(.images+[$rows[].Image]|unique)')
        fi
        PLAN=$(j -c --arg task "$TASK" '.image_backup_mode="local" |
          .image_tags=(.images|map({key:.,value:("jdmc-ha-recovery/"+$task+":"+ltrimstr("sha256:"))})|from_entries)' <<< "$PLAN")
        capture_entrypoints
        save_plan
    fi
    if [[ -e "$ACTIVE" || -L "$ACTIVE" ]]; then
        [[ "$(read_json "$ACTIVE" | j -r .task_id)" == "$TASK" ]] || fail 'another recovery task owns business services'
    fi
    protect_images
    set_phase freezing
    stop false
    PLAN=$(j -c '.frozen=true' <<< "$PLAN")
    save_plan
    set_phase frozen
}
capture() {
    freeze
    if j -e '.captured==true' <<< "$PLAN" >/dev/null; then
        verify_snapshot
        if ! j -e '.storage_scope=="databases"' <<< "$PLAN" >/dev/null; then start_infrastructure; fi
        set_phase captured
        return
    fi
    set_phase capturing
    if j -e '.storage_scope=="databases"' <<< "$PLAN" >/dev/null; then
        j -e '.cold_stopped==true' <<< "$PLAN" >/dev/null || fail 'coordinated database shutdown must complete before capture'
    fi
    if j -e '.storage_scope=="databases"' <<< "$PLAN" >/dev/null; then stop_databases; fi
    stop
    validate_database_links
    local paths source target checksum index=0 checksums='[]'
    paths=$(j -c '.paths[]' <<< "$PLAN")
    mkdir -p -m 700 "$DIRECTORY/files"
    private_directory "$DIRECTORY/files"
    while IFS= read -r source; do
        source=$(j -r . <<< "$source")
        target="$DIRECTORY/files/$index"
        [[ ! -L "$target" ]] || fail 'unsafe recovery file snapshot'
        mkdir -p -m 700 "$target"
        run_quiet 86400 rsync -aHAX --numeric-ids --delete --no-specials -- "$source/" "$target/"
        checksum=$(tree_digest "$target") || fail 'recovery snapshot checksum failed'
        valid_digest "$checksum" || fail 'invalid recovery snapshot checksum'
        checksums=$(j -c --arg checksum "$checksum" '.+[$checksum]' <<< "$checksums")
        index=$((index+1))
    done <<< "$paths"
    case "$(j -r '.image_backup_mode//"archive"' <<< "$PLAN")" in
        local) verify_local_images;;
        archive)
            json_args "$(j -c .images <<< "$PLAN")"
            run_quiet 86400 docker image save -o "$DIRECTORY/images.tar" "${ARGS[@]}"
            chmod 600 "$DIRECTORY/images.tar"
            checksum=$(digest "$DIRECTORY/images.tar") || fail 'recovery image checksum failed'
            valid_digest "$checksum" || fail 'invalid recovery image checksum'
            PLAN=$(j -c --arg checksum "$checksum" '.images_sha256=$checksum' <<< "$PLAN");;
        *) fail 'unsupported recovery image backup mode';;
    esac
    PLAN=$(j -c --argjson checksums "$checksums" '.files_sha256=$checksums|.captured=true' <<< "$PLAN")
    run_quiet 600 sync
    save_plan
    # Both upgrade snapshots must finish before either database is restarted.
    if ! j -e '.storage_scope=="databases"' <<< "$PLAN" >/dev/null; then start_infrastructure; fi
    set_phase captured
}
recover_waf_project() {
    if j -e '.waf!=null' <<< "$PLAN" >/dev/null; then
        local waf_names waf_rows waf_project
        waf_names=$(j -c '[.waf.services[]]' <<< "$PLAN")
        json_args "$waf_names"
        if waf_rows=$(docker inspect "${ARGS[@]}" 2>/dev/null); then
            waf_project=$(printf '%s\n' "$PLAN" "$waf_rows" | j -ers '
              .[0] as $plan | .[1] as $rows |
              [$rows[].Config.Labels["com.docker.compose.project"]] | unique |
              if length==1 and (.[0]|type)=="string" and (.[0]|length)>0 and
                (all($plan.waf.services|to_entries[]; . as $service |
                  any($rows[]; (.Name|ltrimstr("/"))==$service.value and
                    .Config.Labels["com.docker.compose.service"]==$service.key)))
              then .[0] else error("WAF container identity mismatch") end') || fail 'WAF container project identity mismatch'
            PLAN=$(j -c --arg project "$waf_project" '.waf.project=$project' <<< "$PLAN")
        fi
    fi
}
# Runtime sockets are owned by live services, never by a cold file snapshot.
# Protect their exact receiver paths from --delete; do not exclude ordinary
# files in unshare. Escape rsync filter metacharacters in arbitrary filenames.
socket_filters() {
    local root=$1 path pattern list
    SOCKET_FILTERS=()
    list=$(mktemp) || fail 'cannot inspect runtime sockets'
    if ! find "$root" -type s -print0 > "$list"; then rm -f -- "$list"; fail 'cannot inspect runtime sockets'; fi
    while IFS= read -r -d '' path; do
        pattern=${path#"$root"/}
        pattern=${pattern//\\/\\\\}
        pattern=${pattern//\*/\\*}
        pattern=${pattern//\?/\\?}
        pattern=${pattern//\[/\\[}
        SOCKET_FILTERS+=(--filter "P /$pattern")
    done < "$list"
    rm -f -- "$list"
}
check_jdmc_socket() {
    local socket=${JDMC_LICENSE_SOCKET:-/data/jumpserver/core/data/unshare/jdmc.sock} response
    if [[ -n "$PLAN" ]]; then socket=$(j -r --arg fallback "$socket" ' .license_socket//$fallback' <<< "$PLAN"); fi
    # Deployments without JDMC retain the existing installer behavior.
    if ! command -v systemctl >/dev/null || [[ "$(systemctl show jdmc -p LoadState --value 2>/dev/null)" == not-found ]]; then return; fi
    systemctl is-active --quiet jdmc || fail 'JDMC is not running'
    [[ -S "$socket" && ! -L "$socket" ]] || fail 'JDMC socket is unavailable'
    require curl
    # The trusted UDS serves license APIs but does not expose a health route.
    # A 404 on this path still proves the HTTP listener is responsive without
    # evaluating a license during recovery or release.
    response=$(run 15 curl --silent --show-error --max-time 10 --unix-socket "$socket" --output /dev/null --write-out '%{http_code}' http://localhost/jdmc/api/v1/health)
    [[ "$response" == 200 || "$response" == 404 ]] || fail 'JDMC socket did not respond as expected'
}
restore() {
    j -e '(.completed or .releasing)|not' <<< "$PLAN" >/dev/null || fail 'business release has begun; repeated data restoration is prohibited'
    if j -e '.restored==true' <<< "$PLAN" >/dev/null; then
        if [[ "$(j -r .operation <<< "$PLAN")" != upgrade ]] && ! j -e '.storage_scope=="databases"' <<< "$PLAN" >/dev/null; then start_infrastructure; fi
        set_phase restored
        return
    fi
    if ! j -e '.captured==true' <<< "$PLAN" >/dev/null; then
        if [[ "$(j -r .operation <<< "$PLAN")" == upgrade ]]; then
            if j -e '.storage_scope=="databases"' <<< "$PLAN" >/dev/null; then stop false; else stop; fi
        fi
        PLAN=$(j -c '.restored=true|.aborted_before_install=true' <<< "$PLAN")
        save_plan
        if [[ "$(j -r .operation <<< "$PLAN")" != upgrade ]] && ! j -e '.storage_scope=="databases"' <<< "$PLAN" >/dev/null; then start_infrastructure; fi
        set_phase restored
        return
    fi
    verify_snapshot
    # Older recovery points can contain the installer's inherited Compose
    # project name for WAF. If every captured WAF container still exists,
    # recover its project from the actual matching container labels.
    recover_waf_project
    set_phase restoring
    stop
    if [[ "$(j -r '.image_backup_mode//"archive"' <<< "$PLAN")" == archive ]]; then
        run_quiet 86400 docker image load -i "$DIRECTORY/images.tar"
    else
        verify_local_images
    fi
    local originals original reference image targets target index=0 expected config links entry link temporary
    originals=$(j -c '[.containers[],(.waf_containers//{})[]]|.[]' <<< "$PLAN")
    while IFS= read -r original; do
        reference=$(j -r .reference <<< "$original")
        image=$(j -r .image <<< "$original")
        if [[ "$reference" != sha256:* && "$reference" != *@sha256:* ]]; then run_quiet 600 docker tag "$image" "$reference"; fi
    done <<< "$originals"
    targets=$(j -c '.paths[]' <<< "$PLAN")
    while IFS= read -r target; do
        target=$(j -r . <<< "$target")
        [[ "$(realpath -m -- "$target")" == "$target" ]] || fail 'recovery destination changed'
        socket_filters "$target"
        run_quiet 86400 rsync -aHAX --numeric-ids --delete --no-specials "${SOCKET_FILTERS[@]}" -- "$DIRECTORY/files/$index/" "$target/"
        expected=$(j -r --argjson index "$index" '.files_sha256[$index]' <<< "$PLAN")
        verify_checksum tree_digest "$target" "$expected" 'restored files do not match the recovery point'
        index=$((index+1))
    done <<< "$targets"
    config=$(read_json "$DIRECTORY/compose.json")
    config=$(pinned_config "$config")
    atomic "$DIRECTORY/restored-compose.json" "$config"
    PLAN=$(j -c --arg path "$DIRECTORY/restored-compose.json" '.compose_path=$path' <<< "$PLAN")
    links=$(j -c '.links|to_entries[]' <<< "$PLAN")
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        link=$(j -r .key <<< "$entry"); target=$(j -r .value <<< "$entry")
        [[ ! -e "$link" || -L "$link" ]] || fail 'deployment link was replaced by a directory'
        temporary="${link%/*}/.${link##*/}-$TASK"
        if [[ -L "$temporary" ]]; then rm -- "$temporary"; fi
        ln -s -- "$target" "$temporary"
        mv -fT -- "$temporary" "$link"
    done <<< "$links"
    restore_entrypoints
    if j -e '.waf!=null' <<< "$PLAN" >/dev/null; then
        config=$(read_json "$(j -r .waf.compose_path <<< "$PLAN")")
        config=$(printf '%s\n' "$config" "$PLAN" | j -cs '.[1] as $plan | .[0] | .services|=map_values(.image=$plan.waf_images[.container_name]|.restart="no")' | normalize_compose_ulimits)
        atomic "$DIRECTORY/restored-waf-compose.json" "$config"
        PLAN=$(j -c --arg path "$DIRECTORY/restored-waf-compose.json" '.waf.compose_path=$path' <<< "$PLAN")
    fi
    compose "$PLAN" create --force-recreate --no-build --pull never
    if j -e '.waf!=null' <<< "$PLAN" >/dev/null; then compose "$(j -c .waf <<< "$PLAN")" create --force-recreate --no-build --pull never; fi
    run_quiet 600 sync
    PLAN=$(j -c '.restored=true' <<< "$PLAN")
    save_plan
    # During upgrade, restore both nodes before starting either database.
    if [[ "$(j -r .operation <<< "$PLAN")" != upgrade ]] && ! j -e '.storage_scope=="databases"' <<< "$PLAN" >/dev/null; then start_infrastructure; fi
    set_phase restored
}
validate_target_config() {
    local config=$1 original services entry name service previous mounts mount source image field
    original=$(read_json "$DIRECTORY/compose.json")
    j -e '.services|has("postgresql") and has("redis") and has("core")' <<< "$config" >/dev/null || fail 'recovery target is missing required business services'
    services=$(j -c '.services|to_entries[]' <<< "$config")
    while IFS= read -r entry; do
        name=$(j -r .key <<< "$entry"); service=$(j -c .value <<< "$entry")
        previous=$(j -c --arg name "$name" '.services[$name]//{}' <<< "$original")
        printf '%s\n' "$service" "$previous" | j -es --arg name "$name" '
          .[1] as $previous | .[0] | .network_mode!="host" and ((.devices//[]|length)==0) and
          ((.privileged!=true) or ($name=="celery" and $previous.privileged==true))' >/dev/null || fail "recovery target requires an unsupported host resource: $name"
        mounts=$(j -c '.volumes//[]|.[]' <<< "$service")
        while IFS= read -r mount; do
            [[ -n "$mount" ]] || continue
            j -e 'type=="object"' <<< "$mount" >/dev/null || fail 'recovery requires rendered Compose mounts'
            if j -e '.read_only==true' <<< "$mount" >/dev/null; then continue; fi
            source=$(realpath -m -- "$(j -er .source <<< "$mount")")
            if [[ "$(j -r .type <<< "$mount")" == bind ]] && runtime_mount "$name" "$source" "$(j -r .target <<< "$mount")"; then continue; fi
            [[ "$(j -r .type <<< "$mount")" == bind ]] || fail "recovery target requires bind storage: $name"
            if ! inside_roots "$source" "$(j -c .paths <<< "$PLAN")"; then
                j -e --arg source "$source" '(.preserved_paths//[])|index($source)!=null' <<< "$PLAN" >/dev/null || fail "recovery target storage is outside managed roots: $name"
                printf '%s\n' "$service" "$previous" | j -es '.[0].volumes==.[1].volumes' >/dev/null || fail "preserved business storage changed: $name"
            fi
        done <<< "$mounts"
        if ! j -en --arg name "$name" --argjson infra "$INFRA" '$infra|index($name)!=null' >/dev/null; then continue; fi
        j -e --arg name "$name" '.services|has($name)' <<< "$original" >/dev/null || fail "new database infrastructure requires a dedicated recovery adapter: $name"
        image=$(run 600 docker image inspect -f '{{.Id}}' "$(j -r .image <<< "$service")")
        [[ "$image" == "$(j -r --arg name "$name" '.containers[.services[$name]].image' <<< "$PLAN")" ]] || fail "database image changes require a dedicated recovery adapter: $name"
        if [[ "$(j -r .operation <<< "$PLAN")" == upgrade ]]; then
            for field in container_name volumes command entrypoint environment user network_mode; do
                printf '%s\n' "$service" "$previous" | j -es --arg field "$field" '.[0][$field]==.[1][$field]' >/dev/null || fail "database configuration changed outside recovery scope: $name.$field"
            done
        fi
    done <<< "$services"
}
pin_target_images() {
    local config=$1 entries entry name image
    entries=$(j -c '.services|to_entries[]' <<< "$config")
    while IFS= read -r entry; do
        name=$(j -r .key <<< "$entry")
        image=$(run 600 docker image inspect -f '{{.Id}}' "$(j -r .value.image <<< "$entry")")
        config=$(j -c --arg name "$name" --arg image "$image" '.services[$name].image=$image' <<< "$config")
    done <<< "$entries"
    normalize_compose_ulimits <<< "$config"
}
release_item() {
    j -c --arg target "$2" '{project:.name,compose_path:$target,services:(.services|map_values(.container_name))}' <<< "$1"
}
release_restart_policies() {
    # The release configuration is only started after releasing=true is durable.
    # Restore application restart policies then so a proxy that starts before
    # its upstream can recover. Infrastructure retains its running containers.
    printf '%s\n' "$1" "$2" | j -cs --argjson infra "$INFRA" \
        --argjson isolated "$(j -c '(.original_isolated==true) and (.restored==true)' <<< "$PLAN")" '
      .[1] as $original | .[0] | .services |= with_entries(
        .key as $service | $original[.value.container_name] as $container |
        if $isolated or ($infra|index($service)!=null) or $container.running!=true then .
        else ($container.restart//{}) as $policy |
          .value.restart=(
            if ($policy.Name//"") == "" then "no"
            elif $policy.Name=="on-failure" and ($policy.MaximumRetryCount//0)>0
              then "on-failure:"+($policy.MaximumRetryCount|tostring)
            else $policy.Name end)
        end)'
}
verify() {
    j -e '(.releasing or .completed)|not' <<< "$PLAN" >/dev/null || fail 'business release has already begun'
    j -e '.captured or .aborted_before_install' <<< "$PLAN" >/dev/null || fail 'complete recovery point is unavailable'
    local config target item key checksum
    if ! j -e '.restored==true' <<< "$PLAN" >/dev/null; then
        config=$(run 600 bash "$INSTALLER" raw config --format json)
        validate_target_config "$config"
        config=$(pin_target_images "$config")
        target="$DIRECTORY/target-compose.json"
        atomic "$target" "$config"
        item=$(release_item "$config" "$target")
        PLAN=$(printf '%s\n' "$PLAN" "$item" | j -cs '.[1] as $item | .[0] | .release=$item')
        if j -e '.waf!=null' <<< "$PLAN" >/dev/null; then
            config=$(run 600 env -u COMPOSE_PROJECT_NAME bash /opt/current/osm/ngswaf/ngswafctl.sh recovery-config)
            config=$(pin_target_images "$config")
            target="$DIRECTORY/target-waf-compose.json"
            atomic "$target" "$config"
            item=$(release_item "$config" "$target")
            PLAN=$(printf '%s\n' "$PLAN" "$item" | j -cs '.[1] as $item | .[0] | .release_waf=$item')
        fi
    else
        if j -e '.aborted_before_install==true' <<< "$PLAN" >/dev/null; then recover_waf_project; fi
        config=$(read_json "$(j -er .compose_path <<< "$PLAN")")
        config=$(release_restart_policies "$config" "$(j -c .containers <<< "$PLAN")" | normalize_compose_ulimits)
        target="$DIRECTORY/release-compose.json"
        atomic "$target" "$config"
        PLAN=$(j -c --arg path "$target" '.release={project:.project,compose_path:$path,services:.services}' <<< "$PLAN")
        if j -e '.waf!=null' <<< "$PLAN" >/dev/null; then
            config=$(read_json "$(j -er .waf.compose_path <<< "$PLAN")")
            config=$(release_restart_policies "$config" "$(j -c .waf_containers <<< "$PLAN")" | normalize_compose_ulimits)
            target="$DIRECTORY/release-waf-compose.json"
            atomic "$target" "$config"
            PLAN=$(j -c --arg path "$target" '.release_waf=(.waf|.compose_path=$path)' <<< "$PLAN")
        fi
    fi
    compose "$(j -c .release <<< "$PLAN")" config --quiet
    if j -e '.release_waf!=null' <<< "$PLAN" >/dev/null; then compose "$(j -c .release_waf <<< "$PLAN")" config --quiet; fi
    json_args "$(j -c --argjson infra "$INFRA" '[.release.services|to_entries[]|select(.key as $s|$infra|index($s)!=null)|.value]' <<< "$PLAN")"
    wait_healthy "${ARGS[@]}"
    for key in release release_waf; do
        item=$(j -c --arg key "$key" '.[$key]' <<< "$PLAN")
        [[ "$item" != null ]] || continue
        target=$(j -er .compose_path <<< "$item")
        checksum=$(digest "$target") || fail 'release configuration checksum failed'
        valid_digest "$checksum" || fail 'invalid release configuration checksum'
        PLAN=$(j -c --arg key "$key" --arg checksum "$checksum" '.[$key].sha256=$checksum' <<< "$PLAN")
    done
    PLAN=$(j -c '.verified=true' <<< "$PLAN")
    save_plan
}
release() {
    if j -e '.completed==true' <<< "$PLAN" >/dev/null; then clear_active; return; fi
    j -e '.verified==true' <<< "$PLAN" >/dev/null || fail 'business recovery has not been verified'
    local key item isolated original enabled disabled applications infrastructure running='[]' present entries entry name policy count
    local -a up_options=(-d --no-deps --pull never)
    for key in release release_waf; do
        item=$(j -c --arg key "$key" '.[$key]' <<< "$PLAN")
        [[ "$item" != null ]] || continue
        verify_checksum digest "$(j -r .compose_path <<< "$item")" "$(j -r .sha256 <<< "$item")" 'release configuration checksum mismatch'
    done
    check_jdmc_socket
    # Durable decision before any application accepts writes. After this,
    # failures permit forward release retries only, never snapshot restoration.
    PLAN=$(j -c '.releasing=true' <<< "$PLAN")
    save_plan
    set_phase releasing
    isolated=$(j -c '(.original_isolated==true) and (.restored==true)' <<< "$PLAN")
    for key in release release_waf; do
        item=$(j -c --arg key "$key" '.[$key]' <<< "$PLAN")
        [[ "$item" != null ]] || continue
        if [[ "$key" == release ]]; then original=$(j -c .containers <<< "$PLAN"); else original=$(j -c .waf_containers <<< "$PLAN"); fi
        enabled=$(printf '%s\n' "$item" "$original" | j -cs --argjson isolated "$isolated" '.[1] as $original | .[0] | [.services|to_entries[]|select(($isolated|not) and ($original[.value].running!=false))|.key]')
        disabled=$(printf '%s\n' "$item" "$enabled" | j -cs '.[1] as $enabled | .[0] | [.services|keys[]|select(. as $s|$enabled|index($s)==null)]')
        json_args "$disabled"
        if ((${#ARGS[@]})); then compose "$item" stop --timeout 60 "${ARGS[@]}"; fi
        infrastructure=$(j -c --argjson infra "$INFRA" '[.[]|select(. as $s|$infra|index($s)!=null)]' <<< "$enabled")
        applications=$(j -c --argjson infra "$INFRA" '[.[]|select(. as $s|$infra|index($s)==null)]' <<< "$enabled")
        json_args "$infrastructure"
        if ((${#ARGS[@]})); then
            # These containers were started and checked before release.
            # Preserve their identity and replication connections.
            compose_start "$item" up -d --no-deps --no-recreate --pull never "${ARGS[@]}"
        fi
        json_args "$applications"
        if ((${#ARGS[@]})); then
            # HA setup may recreate the external JMS network. Recreate WAF
            # containers so Docker binds them to the current network ID.
            if [[ "$key" == release_waf ]]; then up_options+=(--force-recreate); fi
            compose_start "$item" up "${up_options[@]}" "${ARGS[@]}"
        fi
        running=$(printf '%s\n' "$running" "$item" "$enabled" | j -cs '.[1] as $item | .[2] as $enabled | .[0]+[$item.services[$enabled[]]]')
    done
    if [[ "$isolated" == true ]]; then stop; fi
    json_args "$running"
    wait_healthy "${ARGS[@]}"
    present=$(run 600 docker ps -a --format '{{.Names}}' | j -Rsc 'split("\n")|map(select(length>0))')
    entries=$(j -c '(.containers+(.waf_containers//{}))|to_entries[]' <<< "$PLAN")
    while IFS= read -r entry; do
        name=$(j -r .key <<< "$entry")
        if ! j -e --arg name "$name" 'index($name)!=null' <<< "$present" >/dev/null; then continue; fi
        policy=$(j -r '.value.restart.Name|if .==null or .=="" then "no" else . end' <<< "$entry")
        [[ "$isolated" != true ]] || policy=no
        count=$(j -r '.value.restart.MaximumRetryCount//0' <<< "$entry")
        if [[ "$policy" == on-failure && "$count" != 0 ]]; then policy="$policy:$count"; fi
        run_quiet 600 docker update "--restart=$policy" "$name"
    done <<< "$entries"
    PLAN=$(j -c '.completed=true' <<< "$PLAN")
    save_plan
    clear_active
}
active_plan() {
    RECEIPT=
    if [[ ! -e "$ACTIVE" && ! -L "$ACTIVE" ]]; then return; fi
    private_directory "$ROOT"
    RECEIPT=$(read_json "$ACTIVE")
    local requested_task=$TASK requested_directory=$DIRECTORY
    TASK=$(j -er .task_id <<< "$RECEIPT")
    valid_task "$TASK" || fail 'invalid active recovery identity'
    DIRECTORY="$ROOT/$TASK"
    private_directory "$DIRECTORY"
    [[ "$(j -r .directory <<< "$RECEIPT")" == "$DIRECTORY" ]] || fail 'active recovery directory mismatch'
    PLAN=$(read_json "$DIRECTORY/manifest.json")
    validate_plan
    j -e '.phase as $phase|["freezing","frozen","capturing","captured","restoring","restored","releasing"]|index($phase)!=null' <<< "$RECEIPT" >/dev/null || fail 'invalid active recovery phase'
    if [[ -n "$requested_directory" ]]; then TASK=$requested_task; DIRECTORY=$requested_directory; fi
}
guard() {
    active_plan
    [[ -n "$RECEIPT" ]] || return 0
    if j -e '.completed==true' <<< "$PLAN" >/dev/null; then return; fi
    if [[ "$PURPOSE" == startup ]]; then
        printf 'HA task %s owns startup; service start deferred\n' "$TASK" >&2
        exit 75
    fi
    local identity found=false phase config
    for identity in "${HA_RECOVERY_TASK_ID:-}" "${JDMC_HA_UPGRADE_TASK:-}" "${HA_GUIDED_TASK_ID:-}"; do
        [[ -n "$identity" ]] || continue
        found=true
        [[ "$identity" == "$TASK" ]] || fail 'database migration requires the active HA task identity'
    done
    if [[ "$found" == false && "$PURPOSE" == infrastructure ]]; then exit 75; fi
    [[ "$found" == true ]] || fail 'database migration requires the active HA task identity'
    phase=$(j -r .phase <<< "$RECEIPT")
    [[ "$phase" == captured || "$phase" == restored ]] && j -e '(.releasing or .aborted_before_install)|not' <<< "$PLAN" >/dev/null || fail 'database migration is prohibited while recovery data is incomplete'
    if [[ "$phase" == restored ]]; then j -e '.restored==true' <<< "$PLAN" >/dev/null || fail 'database restore is incomplete'; fi
    j -e '.captured==true' <<< "$PLAN" >/dev/null || fail 'recovery point has not been captured'
    [[ -n "$INSTALLER" ]] || fail 'database migration requires its installer identity'
    config=$(run 600 bash "$INSTALLER" raw config --format json)
    validate_target_config "$config"
}
main() {
    local action=${1:-} value fd owner mode before after pid=${BASHPID:-$$}
    (($#)) && shift
    case "$action" in manifest|check|freeze|cold_stop|capture|restore|start|verify|release|cleanup|guard) ;; *) fail 'unsupported recovery action';; esac
    while (($#)); do
        case "$1" in
            --task-id|--installer|--operation|--purpose)
                (($#>=2)) || fail 'missing recovery argument'
                value=$2
                case "$1" in --task-id) TASK=$value;; --installer) INSTALLER=$value;; --operation) OPERATION=$value;; --purpose) PURPOSE=$value;; esac
                shift 2;;
            --initially-isolated) ISOLATED=true; shift;;
            *) fail 'unsupported recovery argument';;
        esac
    done
    [[ "$OPERATION" == build || "$OPERATION" == upgrade ]] || fail 'invalid recovery operation'
    [[ "$PURPOSE" == startup || "$PURPOSE" == migration || "$PURPOSE" == infrastructure ]] || fail 'invalid recovery purpose'
    # This build-time command must work without jq, root or runtime state.
    if [[ "$action" == manifest ]]; then
        printf '%s\n' '{"version":1,"coordinated_startup":1,"paired_cold_backup":1,"native_components":"unchanged"}'
        return
    fi
    # No task: preserve standalone lifecycle even before recovery tools exist.
    if [[ "$action" == guard && ! -e "$ACTIVE" && ! -L "$ACTIVE" ]]; then return; fi
    check_jq
    if [[ "$action" == guard ]]; then guard; return; fi
    valid_task "$TASK" && [[ -n "$INSTALLER" && "$EUID" == 0 ]] || fail 'invalid recovery identity or privileges'
    if [[ "$ISOLATED" == true && "$action" != freeze && "$action" != capture ]]; then fail 'initial isolation is only accepted during freeze or capture'; fi
    umask 077
    mkdir -p -m 700 "$ROOT"
    private_directory "$ROOT"
    DIRECTORY="$ROOT/$TASK"
    mkdir -p -m 700 "$DIRECTORY"
    private_directory "$DIRECTORY"
    [[ ! -L "$ROOT/operation.lock" && ( ! -e "$ROOT/operation.lock" || -f "$ROOT/operation.lock" ) ]] || fail 'unsafe recovery lock'
    exec {fd}<>"$ROOT/operation.lock"
    read -r owner mode <<< "$(stat -Lc '%u %a' -- "/proc/$pid/fd/$fd")"
    before=$(stat -c '%d:%i' -- "$ROOT/operation.lock")
    after=$(stat -Lc '%d:%i' -- "/proc/$pid/fd/$fd")
    [[ "$owner" == "$EUID" && "$before" == "$after" && ! -L "$ROOT/operation.lock" ]] && (( (8#$mode & 077)==0 )) || fail 'unsafe recovery lock'
    flock -xn "$fd" || fail 'another recovery operation holds the lock'
    active_plan
    if [[ -n "$RECEIPT" ]]; then
        if j -e '.completed==true' <<< "$PLAN" >/dev/null; then
            rm -- "$ACTIVE"; sync -f "${ACTIVE%/*}"; RECEIPT=
        else
            [[ "$(j -r .task_id <<< "$RECEIPT")" == "$TASK" ]] || fail 'another recovery task owns business services'
        fi
    fi
    case "$action" in
        check) check;;
        freeze) freeze;;
        capture) capture;;
        *)
            PLAN=$(read_json "$DIRECTORY/manifest.json")
            validate_plan
            if [[ "$action" != release && "$action" != cleanup ]]; then
                j -e '.completed!=true' <<< "$PLAN" >/dev/null || fail 'recovery already completed; repeated rollback is prohibited'
                j -e '.releasing!=true' <<< "$PLAN" >/dev/null || fail 'business release has begun; only forward release retry is allowed'
            fi
            case "$action" in
                cold_stop)
                    j -e '.storage_scope=="databases" and .frozen==true and .captured!=true and .restored!=true' <<< "$PLAN" >/dev/null || fail 'cold shutdown requires a new frozen task'
                    set_phase capturing
                    stop_databases
                    PLAN=$(j -c --argjson proof "$(shutdown_proof)" '.cold_stopped=true|.cold_shutdown=$proof' <<< "$PLAN")
                    save_plan
                    j -cn --arg task "$TASK" --argjson proof "$(j -c .cold_shutdown <<< "$PLAN")" '{task_id:$task,shutdown:$proof,success:true}'
                    return;;
                restore) restore;;
                start)
                    j -e '.captured or .aborted_before_install' <<< "$PLAN" >/dev/null || fail 'recovery point has not been captured'
                    if [[ -n "$RECEIPT" && "$(j -r .phase <<< "$RECEIPT")" == restoring ]]; then
                        j -e '.restored==true' <<< "$PLAN" >/dev/null || fail 'database restore is incomplete'
                    fi
                    start_infrastructure
                    if j -e '.restored==true' <<< "$PLAN" >/dev/null; then set_phase restored; else set_phase captured; fi;;
                verify) verify;;
                release) release;;
                cleanup) cleanup_images;;
            esac;;
    esac
    j -cn --arg task "$TASK" --arg phase "$action" '{task_id:$task,phase:$phase,success:true}'
}
main "$@"
