#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/bash/monitoring/failed-login-detector.sh"
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

cat > "$TEMP_DIR/auth.log" <<'EOF'
Jan 01 00:00:01 host sshd[1]: Failed password for root from 192.0.2.10 port 22 ssh2
Jan 01 00:00:02 host sshd[2]: Failed password for invalid user admin from 192.0.2.10 port 22 ssh2
Jan 01 00:00:03 host sshd[3]: Failed password for root from 192.0.2.20 port 22 ssh2
Jan 01 00:00:04 host sshd[4]: Accepted password for root from 192.0.2.30 port 22 ssh2
EOF

output="$("$SCRIPT" "$TEMP_DIR/auth.log" 1)" || fail "log scan should succeed"
assert_contains "$output" "top 1"
assert_contains "$output" "2  192.0.2.10"
[[ "$output" != *"192.0.2.20"* ]] || fail "TOP_N should limit the output"

printf 'Accepted password for root from 192.0.2.30 port 22 ssh2\n' > "$TEMP_DIR/clean.log"
clean_output="$("$SCRIPT" "$TEMP_DIR/clean.log")" || fail "clean log should succeed"
assert_contains "$clean_output" "No failed password attempts found"

if "$SCRIPT" "$TEMP_DIR/auth.log" 0 >"$TEMP_DIR/invalid-output" 2>&1; then
    fail "zero TOP_N should fail"
fi
assert_contains "$( < "$TEMP_DIR/invalid-output" )" "TOP_N must be a positive integer"

echo "PASS: failed-login-detector.sh"
