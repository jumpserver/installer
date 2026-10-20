#!/usr/bin/env bash

function prepare_ansible_executor() {
  local credential_dir image
  if [[ "$(get_config_or_env ANSIBLE_EXECUTOR_ENABLED)" == "0" ]]; then
    return 0
  fi

  credential_dir="${CONFIG_DIR}/ansible-executor"
  image="$(get_image_namespace)/ansible-executor-ssh:latest"
  mkdir -p "${credential_dir}" || return 1
  chmod 700 "${credential_dir}" || return 1
  # Use the shipped SSH tools; the host needs no additional key-generation package.
  docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges:true \
    --user 0 --entrypoint /bin/sh \
    --mount "type=bind,src=${credential_dir},dst=/keys" \
    --mount "type=bind,src=${PROJECT_DIR}/config_init/ansible-executor/init.sh,dst=/bootstrap.sh,readonly" \
    "${image}" /bootstrap.sh /keys
}
