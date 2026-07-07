#!/usr/bin/env bash
#

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/const.sh"
. "${BASE_DIR}/gists/common.sh"
. "${BASE_DIR}/gists/conf.sh"
. "${BASE_DIR}/gists/openbao.sh"
. "${BASE_DIR}/gists/image.sh"
. "${BASE_DIR}/gists/service.sh"

namespace=${NAMESPACE:-jumpserver}
