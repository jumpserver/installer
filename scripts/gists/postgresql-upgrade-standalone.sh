#!/usr/bin/env bash
# PG18_* variables are inputs to the separately sourced migration library.
# shellcheck disable=SC2034

postgresql_upgrade_is_internal() {
  [[ "$(get_config DB_ENGINE)" == postgresql && "$(get_config DB_HOST)" == postgresql && "$(get_config HA_MODE)" != 1 ]]
}

postgresql_upgrade_pending() {
  local directory phase
  postgresql_upgrade_is_internal || return 1
  directory="$(get_config VOLUME_DIR)/postgresql/data.upgrade18"
  [[ -e "${directory}/phase" ]] || return 1
  phase=$(cat "${directory}/phase") || return 0
  [[ "${phase}" != complete ]]
}

postgresql_upgrade_start_guard() {
  if [[ "${PG18_UPGRADE_ACTIVE:-0}" != 1 ]] && postgresql_upgrade_pending; then
    log_error 'PostgreSQL migration is pending; retry the same upgrade before starting services'
    return 1
  fi
}

upgrade_internal_postgresql() {
  local version container policy running retries service cmd
  local -a names=() services=()
  postgresql_upgrade_is_internal || return 0
  PG18_DATA="$(get_config VOLUME_DIR)/postgresql/data"
  version=$(cat "${PG18_DATA}/PG_VERSION" 2>/dev/null || true)
  if [[ ! -e "${PG18_DATA}.upgrade18/phase" ]]; then
    [[ -n "${version}" && "${version}" -lt 18 ]] || return 0
  elif [[ "$(cat "${PG18_DATA}.upgrade18/phase")" == complete ]]; then
    return 0
  fi
  . "${SCRIPT_DIR}/gists/postgresql-upgrade.sh"
  PG18_CONTAINER=jms_postgresql PG18_USER=$(get_config DB_USER) PG18_PASSWORD=$(get_config DB_PASSWORD) PG18_PORT=$(get_config DB_PORT 5432)
  pg18_paths || return 1
  exec 201>"${PG18_WORK}/upgrade.lock"
  flock -n 201 || { log_error "Another PostgreSQL migration is running"; return 1; }
  export PG18_UPGRADE_ACTIVE=1
  if [[ ! -f "${PG18_WORK}/phase" ]]; then
    docker start "${PG18_CONTAINER}" >/dev/null && wait_container_healthy "${PG18_CONTAINER}" || return 1
    pg18_preflight || return 1
  fi
  # Save restart intent before stopping anything. A host restart during the
  # migration must not restart an old application against a partially upgraded DB.
  if [[ ! -f "${PG18_WORK}/writers" ]]; then
    for service in $(get_enabled_services); do
      container="jms_${service}"
      [[ "${service}" != ansible-executor ]] || container=jms_ansible_executor
      names+=("${container}")
    done
    : >"${PG18_WORK}/writers.partial"
    for container in "${names[@]}"; do
      if docker inspect "${container}" >/dev/null 2>&1; then
        docker inspect -f '{{.Name}} {{.State.Running}} {{.HostConfig.RestartPolicy.Name}} {{.HostConfig.RestartPolicy.MaximumRetryCount}} {{index .Config.Labels "com.docker.compose.service"}}' "${container}" >>"${PG18_WORK}/writers.partial" || return 1
      fi
    done
    chmod 600 "${PG18_WORK}/writers.partial" && sync "${PG18_WORK}/writers.partial" &&
      mv "${PG18_WORK}/writers.partial" "${PG18_WORK}/writers" || return 1
  fi
  [[ -f "${PG18_WORK}/phase" ]] || pg18_save phase reserved || return 1
  while read -r container running policy retries service; do
    [[ "${container}" == /jms_* && "${service}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    if docker inspect "${container}" >/dev/null 2>&1; then
      docker update --restart=no "${container}" >/dev/null && docker stop "${container}" >/dev/null || return 1
      [[ "$(docker inspect -f '{{.State.Running}}' "${container}")" == false ]] || return 1
    fi
  done <"${PG18_WORK}/writers"
  # The data container's old image remains valid until the staged cluster is ready.
  if [[ ! -f "${PG18_WORK}/phase" || "$(cat "${PG18_WORK}/phase")" == preparing || "$(cat "${PG18_WORK}/phase")" == reserved ]]; then
    docker start "${PG18_CONTAINER}" >/dev/null && wait_container_healthy "${PG18_CONTAINER}" || return 1
  fi
  pg18_prepare && pg18_cutover || return 1
  gen_safe_config >/dev/null || return 1
  cmd=$(get_db_compose_cmd db) || return 1
  ${cmd} up -d --no-deps --force-recreate postgresql || return 1
  wait_container_healthy "${PG18_CONTAINER}" || return 1
  [[ "$(pg18_sql "select current_setting('server_version_num')::int/10000;")" == 18 ]] || return 1
  pg18_save phase switched
}

complete_internal_postgresql_upgrade() {
  local container running policy retries service cmd state deadline timeout
  local -a services=()
  [[ "${PG18_UPGRADE_ACTIVE:-0}" == 1 && -f "${PG18_WORK:-}/writers" ]] || return 0
  # Called only after application schema and JDMC upgrades have succeeded.
  while read -r container running policy retries service; do
    [[ "${running}" == true ]] || continue
    services+=("${service}")
  done <"${PG18_WORK}/writers"
  if (( ${#services[@]} )); then
    prepare_services_for_start "${services[@]}" || return 1
    cmd=$(get_docker_compose_cmd_line) || return 1
    ${cmd} up -d "${services[@]}" || return 1
  fi
  timeout=$(get_config CONTAINER_HEALTH_TIMEOUT 300)
  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=300
  deadline=$((SECONDS + timeout))
  while read -r container running policy retries service; do
    if [[ "${running}" == true ]]; then
      while :; do
        state=$(docker inspect -f '{{if not .State.Running}}{{.State.Status}}{{else if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container}") || return 1
        [[ "${state}" != healthy && "${state}" != running ]] || break
        if [[ "${state}" == exited || "${state}" == dead ]] || (( SECONDS >= deadline )); then
          log_error "Failed to recover ${container}: ${state}"
          return 1
        fi
        sleep 2
      done
    fi
    [[ "${policy}" =~ ^(no|always|unless-stopped|on-failure)$ && "${retries}" =~ ^[0-9]+$ ]] || return 1
    if [[ "${policy}" == on-failure && "${retries}" != 0 ]]; then policy+="${policy:+:}${retries}"; fi
    if docker inspect "${container}" >/dev/null 2>&1; then docker update --restart="${policy}" "${container}" >/dev/null || return 1; fi
  done <"${PG18_WORK}/writers"
  pg18_save phase complete || return 1
  log_success "PostgreSQL is now ${PG18_IMAGE}; original data and migration backup retained in ${PG18_WORK}"
}

# EXIT cleanup must re-fence even a partly started application on recovery failure.
fence_internal_postgresql_upgrade() {
  local service container
  [[ "${PG18_UPGRADE_ACTIVE:-0}" == 1 && -f "${PG18_WORK:-}/phase" ]] || return 0
  for service in $(get_enabled_services); do
    container="jms_${service}"
    [[ "${service}" != ansible-executor ]] || container=jms_ansible_executor
    if docker inspect "${container}" >/dev/null 2>&1; then
      docker update --restart=no "${container}" >/dev/null && docker stop "${container}" >/dev/null || return 1
    fi
  done
}
