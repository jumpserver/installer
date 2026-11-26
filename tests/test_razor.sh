#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

if ! docker compose version &>/dev/null; then
  printf 'SKIP: Docker Compose is unavailable\n'
  exit 0
fi

cd "${TEST_ROOT}"
export HOSTNAME=test-host
export JS_CONFIG_DIR="${TEST_TMP_ROOT}/razor"
mkdir -p "${JS_CONFIG_DIR}"
cp config-example.txt "${JS_CONFIG_DIR}/config.txt"
. ./scripts/utils.sh
set_config USE_XPACK 1
set_config VOLUME_DIR "${JS_CONFIG_DIR}/data"
set_config RAZOR_RDP_PORT 13389
set_config MAGNUS_PORT 15525
set_config NEC_VNC_PORT 25900
cp "${CONFIG_FILE}" "${CONFIG_SAFE_FILE}"
compose_cmd=$(get_docker_compose_cmd_line)
${compose_cmd} --env-file "${CONFIG_FILE}" config --format json >"${JS_CONFIG_DIR}/compose.json"

python3 - "${JS_CONFIG_DIR}" <<'PYTEST'
import json
import sys
from pathlib import Path

config = Path(sys.argv[1])
services = json.loads((config / "compose.json").read_text())["services"]
assert "magnus" not in services and "nec" not in services
razor = services["razor"]
ports = {int(p["target"]): int(p["published"]) for p in razor["ports"]}
assert ports == {3389: 13389, 5525: 15525, 15900: 25900}, ports
mounts = {v["target"]: Path(v["source"]) for v in razor["volumes"]}
for name in ("razor", "magnus", "nec"):
    assert mounts[f"/opt/{name}/data"] == config / "data" / name / "data"
for name in ("magnus", "nec"):
    assert mounts[f"/opt/{name}/data/certs"] == config / "certs"
assert mounts["/opt/razor/cert"] == config / "nginx/cert"
assert razor["healthcheck"]["test"] == ["CMD-SHELL", "check http://localhost:8084/razor/health/"]
PYTEST
printf 'PASS: Razor exposes the bundled services and preserves their data and certificates\n'
