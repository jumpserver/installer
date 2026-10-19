#!/usr/bin/env bash

private_receipt() {
    local owner mode
    [[ ! -L "$1" && -f "$1" ]] || return 1
    owner=$(stat -c '%u' -- "$1") || return 1
    mode=$(stat -c '%a' -- "$1") || return 1
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 077) == 0 ))
}

validate() {
    local task="${JDMC_HA_UPGRADE_TASK:-}"
    local directory="${JDMC_HA_UPGRADE_DIR:-}"
    local role="${ROLE:-}"
    local resolved

    [[ "$EUID" == 0 && "$task" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
    [[ "$role" == master || "$role" == standby ]] || return 1
    private_receipt /data/ha-toolkit/upgrading || return 1
    jq -e -s --arg task "$task" --arg role "$role" '
        length == 1 and (.[0] |
            type == "object" and .id == $task and .role == $role)
    ' /data/ha-toolkit/upgrading >/dev/null || return 1

    [[ -d "$directory" && ! -L "$directory" && "${directory##*/}" == "$task" ]] || return 1
    resolved=$(readlink -f -- "$directory") || return 1
    [[ "$resolved" == "$directory" ]] || return 1
    private_receipt "$directory/backup.json" || return 1
    jq -e -s --arg task "$task" '
        length == 1 and (.[0] |
            type == "object" and .task_id == $task and
            (.sha256 | type == "string" and length == 64))
    ' "$directory/backup.json" >/dev/null || return 1
    [[ "${SKIP_BACKUP_DB:-}" == 1 ]]
}

if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' 'Coordinated upgrade admission failed: required command jq is unavailable.' >&2
    exit 1
fi
if ! validate 2>/dev/null; then
    printf '%s\n' 'Coordinated upgrade admission failed; inspect the original HA task.' >&2
    exit 1
fi
