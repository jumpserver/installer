#!/usr/bin/env bash

# Compatibility aliases for one migration cycle. New installer code should use
# the JDMC names from jdmc.sh.
if ! declare -F is_jdmc_enabled &>/dev/null; then
  JDMC_GIST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  . "${JDMC_GIST_DIR}/jdmc.sh"
fi

KOTL_SERVICE_NAME=${KOTL_SERVICE_NAME:-${JDMC_LEGACY_SERVICE_NAME}}
KOTL_CORE_SOCKET_PATH=${KOTL_CORE_SOCKET_PATH:-${JDMC_CORE_SOCKET_PATH}}

function is_kotl_enabled() { is_jdmc_enabled "$@"; }
function should_include_kotl_image() { should_include_jdmc_image "$@"; }
function get_kotl_image() { get_jdmc_image "$@"; }
function configure_kotl() { configure_jdmc "$@"; }
function check_kotl_runtime() { check_jdmc_runtime "$@"; }
function check_kotl_installed() { check_jdmc_installed "$@"; }
function run_kotl_package_action() { run_jdmc_package_action "$@"; }
function install_kotl() { install_jdmc "$@"; }
function upgrade_kotl() { upgrade_jdmc "$@"; }
function start_kotl() { start_jdmc "$@"; }
function stop_kotl() { stop_jdmc "$@"; }
function restart_kotl() { restart_jdmc "$@"; }
function status_kotl() { status_jdmc "$@"; }
function tail_kotl() { tail_jdmc "$@"; }
function disable_kotl() { disable_jdmc "$@"; }
