#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/bash/backup/log-rotate.sh"
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

help_output="$("$SCRIPT" --help)" || fail "--help should succeed"
assert_contains "$help_output" "Usage:"

mkdir "$TEMP_DIR/logs"
printf 'middle\n' > "$TEMP_DIR/logs/middle.log"
printf 'old\n' > "$TEMP_DIR/logs/old.log"
printf 'fresh\n' > "$TEMP_DIR/logs/fresh.log"
printf 'nested\n' > "$TEMP_DIR/logs/nested.log"
mkdir "$TEMP_DIR/logs/nested"
mv "$TEMP_DIR/logs/nested.log" "$TEMP_DIR/logs/nested/nested.log"
touch -d "10 days ago" "$TEMP_DIR/logs/middle.log"
touch -d "20 days ago" "$TEMP_DIR/logs/old.log"
touch -d "1 day ago" "$TEMP_DIR/logs/fresh.log"

if dry_run_output="$(cd "$TEMP_DIR" && "$SCRIPT" 7 14 2>&1)"; then
    :
else
    fail "dry run should succeed"
fi
assert_contains "$dry_run_output" "Would compress 1 file(s)"
assert_contains "$dry_run_output" "Would delete 1 log file(s)"
[[ -f "$TEMP_DIR/logs/middle.log" ]] || fail "dry run should preserve compressible logs"
[[ -f "$TEMP_DIR/logs/old.log" ]] || fail "dry run should preserve old logs"

apply_output="$(cd "$TEMP_DIR" && "$SCRIPT" --apply 7 14 2>&1)" || fail "apply should succeed"
assert_contains "$apply_output" "Compressed 1 file(s)"
assert_contains "$apply_output" "Deleted 1 log file(s)"
[[ ! -f "$TEMP_DIR/logs/middle.log" ]] || fail "compressed log should be removed"
[[ ! -f "$TEMP_DIR/logs/old.log" ]] || fail "old log should be removed"
[[ -f "$TEMP_DIR/logs/fresh.log" ]] || fail "fresh log should be preserved"
[[ -f "$TEMP_DIR/logs/nested/nested.log" ]] || fail "nested log should be preserved"
archive_count="$(find "$TEMP_DIR/logs" -maxdepth 1 -type f -name 'logs-*.tar.gz' | wc -l | tr -d ' ')"
[[ "$archive_count" -eq 1 ]] || fail "expected one log archive, found $archive_count"

if "$SCRIPT" 14 7 >"$TEMP_DIR/invalid-output" 2>&1; then
    fail "reversed age range should fail"
fi
assert_contains "$( < "$TEMP_DIR/invalid-output" )" "AGE_YOUNG must be less than AGE_OLD"

echo "PASS: log-rotate.sh"
