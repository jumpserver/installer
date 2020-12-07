#!/usr/bin/env bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

(bash "${BASE_DIR}/1_install_docker.sh")
(bash "${BASE_DIR}/2_load_images.sh")
(bash "${BASE_DIR}/3_config_jumpserver.sh")
