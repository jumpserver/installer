#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
. "${TEST_ROOT}/scripts/gists/service.sh"

case_dir="${TEST_TMP_ROOT}/chen-volume"
mkdir -p "${case_dir}"
VERSION=dev-ce
enabled=1
image_user=10001:10001
get_config_or_env() { [[ "$1" != CHEN_ENABLED ]] || printf '%s\n' "${enabled}"; }
get_config() { [[ "$1" != VOLUME_DIR ]] || printf '%s\n' "${case_dir}"; }
get_image_namespace() { printf 'jumpserver\n'; }
log_error() { printf '%s\n' "$*" >&2; }
docker() {
  if [[ "$1 $2" == 'image inspect' ]]; then printf '%s\n' "${image_user}"; else return 1; fi
}
chown() { printf '%s\n' "$*" >>"${case_dir}/ownership.log"; }

enabled=0
prepare_chen_volume
[[ ! -e "${case_dir}/chen" ]] || fail 'disabled Chen must not prepare directories'
enabled=1
image_user=''
prepare_chen_volume
[[ ! -e "${case_dir}/chen" ]] || fail 'legacy root image must not migrate ownership'

image_user=10001:10001
mkdir -p "${case_dir}/chen/data/keys" "${case_dir}/chen/data/certs"
printf 'retained registration\n' >"${case_dir}/chen/data/keys/.access_key"
prepare_chen_volume
[[ -d "${case_dir}/chen/data/go" && -d "${case_dir}/chen/data/logs" ]] || fail 'runtime state directories missing'
assert_eq 'retained registration' "$(cat "${case_dir}/chen/data/keys/.access_key")" 'existing registration must survive'
assert_contains "$(cat "${case_dir}/ownership.log")" "-h 10001:10001 ${case_dir}/chen/data"
assert_eq "-hR 10001:10001 ${case_dir}/chen/data/keys ${case_dir}/chen/data/logs ${case_dir}/chen/data/go" \
  "$(tail -n 1 "${case_dir}/ownership.log")" 'ownership change must stay inside Chen runtime state'

rm -rf "${case_dir}/chen/data/go"
mkdir -p "${case_dir}/external"
ln -s "${case_dir}/external" "${case_dir}/chen/data/go"
: >"${case_dir}/ownership.log"
if prepare_chen_volume 2>/dev/null; then fail 'state symlinks must not redirect ownership changes'; fi
[[ ! -s "${case_dir}/ownership.log" ]] || fail 'invalid directory must fail before changing ownership'

rm "${case_dir}/chen/data/go"
docker() { return 1; }
if prepare_chen_volume 2>/dev/null; then fail 'missing image must fail before startup'; fi
printf 'PASS: Chen data ownership migration is scoped and preserves registration\n'
