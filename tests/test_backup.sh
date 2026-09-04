#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/backup"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"

. "${TEST_ROOT}/scripts/5_db_backup.sh"

DB_HOST=db
DB_PORT=3306
DB_USER=user
DB_PASSWORD=password
DB_NAME=jumpserver
db_images=mysql:test
docker() { return 1; }

backup_file="${test_dir}/audit.sql.gz"
if backup_audits_mysql "${backup_file}"; then
  fail 'audit backup must fail when mysqldump fails'
fi

printf 'PASS: audit backup propagates mysqldump failures\n'
