#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/bash/backup/backup.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_contains() {
    local haystack="$1" needle="$2"
    [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

help_output="$(bash "$SCRIPT" --help)" || fail "--help should succeed"
assert_contains "$help_output" "Usage:"

target="$TEMP_DIR/target"
backup="$TEMP_DIR/backups"
mkdir -p "$target"
printf 'sample\n' > "$target/sample.txt"

dry_run_output="$(bash "$SCRIPT" "$target" "$backup")" || fail "default dry run should succeed"
assert_contains "$dry_run_output" "DRY RUN"
[[ ! -d "$backup" ]] || fail "dry run should not create the backup directory"

apply_output="$(bash "$SCRIPT" --apply "$target" "$backup" 1)" || fail "apply should succeed"
assert_contains "$apply_output" "Verified: 1 file(s)"
archive_count="$(find "$backup" -maxdepth 1 -type f -name 'backup-*.tar.gz' | wc -l | tr -d ' ')"
[[ "$archive_count" -eq 1 ]] || fail "expected one backup archive, found $archive_count"

if bash "$SCRIPT" "$target" "$backup" 0 >"$TEMP_DIR/invalid-output" 2>&1; then
    fail "zero retention count should fail"
fi
assert_contains "$( < "$TEMP_DIR/invalid-output" )" "N must be a positive integer"

echo "PASS: backup.sh"
