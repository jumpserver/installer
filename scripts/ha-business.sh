#!/usr/bin/env bash
HA_CHILD_SHELLOPTS=$SHELLOPTS
set -eE -o pipefail
umask 077

business_pid=$BASHPID
trap 'result=$?; if (( result != 0 )) && [[ "$BASHPID" == "$business_pid" ]]; then printf "%s\n" "{\"error\":\"business operation failed; inspect protected HA task state\"}"; fi' EXIT
INSTALLER="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")/jmsctl.sh"
ROOT=/data/ha-toolkit

fail() { exit 1; }
run() {
    local seconds=$1 output
    shift
    output=$(env "SHELLOPTS=$HA_CHILD_SHELLOPTS" timeout --signal=KILL "$seconds" "$@" 2>/dev/null) || fail
    printf '%s' "$output"
}
atomic() {
    local path=$1 value=$2 temporary
    mkdir -p -- "${path%/*}" || fail
    temporary=$(mktemp "${path%/*}/.business-XXXXXX") || fail
    if ! { printf '%s' "$value" > "$temporary" &&
        sync -- "$temporary" && mv -fT -- "$temporary" "$path" && sync -- "${path%/*}"; }; then
        rm -f -- "$temporary"
        fail
    fi
}
read_state() {
    local owner mode
    [[ ! -L "$1" && -f "$1" ]] || fail
    owner=$(stat -c '%u' -- "$1") || fail
    mode=$(stat -c '%a' -- "$1") || fail
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || fail
    (( (8#$mode & 077) == 0 )) || fail
    jq -ce -s 'if length == 1 and (.[0] | type == "object") then .[0] else error("invalid state") end' "$1" || fail
}
services() {
    local value
    value=$(run 60 bash "$INSTALLER" show_services) || fail
    jq -cn --arg value "$value" '
        # jq 1.5 may be built without the Oniguruma regex library.
        def space: "\t\n\u000b\f\r \u0085\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000";
        $value | explode |
        map(. as $c | if (space | explode | index($c)) != null then 32 else . end) |
        implode | split(" ") | map(select(length > 0)) |
        map(select(. != "postgresql" and . != "mysql" and . != "mariadb" and
            . != "redis" and . != "es" and . != "minio" and . != "loki"))' || fail
}
valid_services() {
    jq -e 'type == "array" and length > 0 and all(.[];
        type == "string" and length > 0 and
        all(explode[]; (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or
            (. >= 97 and . <= 122) or . == 95 or . == 45) and
        . != "postgresql" and . != "mysql" and . != "mariadb" and
        . != "redis" and . != "es" and . != "minio" and . != "loki")' <<< "$1" >/dev/null || fail
}
inspect() {
    local names=$1 text rows
    local -a containers=()
    text=$(jq -er '.[] | "jms_" + .' <<< "$names") || fail
    while IFS= read -r value; do containers+=("$value"); done <<< "$text"
    rows=$(run 60 docker inspect "${containers[@]}") || fail
    jq -ce --argjson names "$names" 'if type == "array" and length == ($names | length)
        then . else error("inventory mismatch") end' <<< "$rows" || fail
}
main() {
    local action=${1:-} task='' guard path state names rows active enabled policy value name
    local -a arguments=()
    [[ "$EUID" == 0 ]] || fail
    command -v jq >/dev/null || fail
    shift || fail
    if (( $# )); then
        [[ $# == 2 && "$1" == --task-id ]] || fail
        task=$2
    fi
    case "$action" in capabilities|check|stop|status|start|recreate|restore_policies) ;; *) fail ;; esac
    if [[ "$action" == capabilities ]]; then
        printf '%s\n' '{"schema_version":1,"no_database_rebuild":true}'
        return
    fi
    if [[ "$action" == check ]]; then
        names=$(services) || fail
        valid_services "$names"
        active=$(run 60 docker ps --filter 'name=^jms_' --format '{{.Names}}') || fail
        jq -ne --arg active "$active" --argjson names "$names" '
            ($names + ["postgresql","mysql","mariadb","redis","es","minio","loki"] |
                map("jms_" + .)) as $allowed |
            all($active | split("\n")[] | select(length > 0);
                . as $name | $allowed | index($name) != null)' >/dev/null || fail
        rows=$(inspect "$names") || fail
        jq -e 'all(.[]; .State.Running == true and (.State.Health.Status // "healthy") == "healthy")' <<< "$rows" >/dev/null || fail
        printf '%s\n' '{"healthy":true}'
        return
    fi
    [[ "$task" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail
    guard="$ROOT/detaching"
    [[ ! -L "$guard" && -f "$guard" ]] || fail
    IFS= read -r value < "$guard" || [[ -n "$value" ]] || fail
    [[ "$value" == "$task" ]] || fail
    path="$ROOT/detach/$task/business.json"
    [[ ! -L "$ROOT" && ! -L "$ROOT/detach" && ! -L "${path%/*}" ]] || fail
    if [[ -e "$path" || -L "$path" ]]; then
        state=$(read_state "$path") || fail
        jq -e --arg task "$task" '.task_id == $task' <<< "$state" >/dev/null || fail
        names=$(jq -ce '.services' <<< "$state") || fail
        valid_services "$names"
    elif [[ "$action" == stop ]]; then
        names=$(services) || fail
        valid_services "$names"
        rows=$(inspect "$names") || fail
        state=$(jq -cn --arg task "$task" --argjson names "$names" --argjson rows "$rows" '
            {task_id:$task,services:$names,containers:($rows | map({
                key:(.Name | ltrimstr("/")),
                value:{running:.State.Running,restart:.HostConfig.RestartPolicy}}) | from_entries)}') || fail
        atomic "$path" "$state"
    elif [[ "$action" == status ]]; then
        printf '%s\n' '{"stopped":false,"prepared":false}'
        return
    else
        fail
    fi
    jq -e '. as $state | all(.services[]; . as $name | $state.containers["jms_" + $name] |
        (.running | type == "boolean") and (.restart | type == "object") and
        (.restart.Name | type == "string"))' <<< "$state" >/dev/null || fail
    value=$(jq -er '.[]' <<< "$names") || fail
    while IFS= read -r name; do arguments+=("$name"); done <<< "$value"
    if [[ "$action" == stop ]]; then
        for name in "${arguments[@]}"; do run 60 docker update --restart=no "jms_$name" >/dev/null; done
        run 600 bash "$INSTALLER" raw stop -t 30 "${arguments[@]}" >/dev/null
        rows=$(inspect "$names") || fail
        jq -e 'all(.[]; .State.Running == false)' <<< "$rows" >/dev/null || fail
        state=$(jq -c '.stopped = true' <<< "$state") || fail
        atomic "$path" "$state"
    elif [[ "$action" != status ]]; then
        enabled=$(jq -cr '[.services[] as $name |
            select(.containers["jms_" + $name].running == true) | $name]' <<< "$state") || fail
        if [[ "$action" != restore_policies ]] && [[ "$(jq 'length' <<< "$enabled")" != 0 ]]; then
            local -a start_args=(bash "$INSTALLER" raw up -d --no-deps)
            [[ "$action" != recreate ]] || start_args+=(--force-recreate)
            value=$(jq -er '.[]' <<< "$enabled") || fail
            while IFS= read -r name; do start_args+=("$name"); done <<< "$value"
            run 600 "${start_args[@]}" >/dev/null
        fi
        for name in "${arguments[@]}"; do
            policy=$(jq -er --arg name "jms_$name" '
                .containers[$name].restart |
                if type != "object" or (.Name | type) != "string" then error("invalid policy")
                elif .Name == "" then "no"
                elif .Name == "on-failure" and (.MaximumRetryCount // 0) != 0
                    then .Name + ":" + (.MaximumRetryCount | tostring)
                else .Name end' <<< "$state") || fail
            run 60 docker update "--restart=$policy" "jms_$name" >/dev/null
        done
        state=$(jq -c '.stopped = false' <<< "$state") || fail
        atomic "$path" "$state"
    fi
    rows=$(inspect "$names") || fail
    jq -cn --argjson rows "$rows" '{schema_version:1,prepared:true,stopped:all($rows[];.State.Running == false)}'
}
(main "$@") 2>/dev/null
