#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/bash/monitoring/disk-memory-monitor.sh"
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

mkdir "$TEMP_DIR/bin"
cat > "$TEMP_DIR/bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/mock 100 50 50 50%% /\n'
EOF
cat > "$TEMP_DIR/bin/free" <<'EOF'
#!/usr/bin/env bash
printf '              total        used        free      shared  buff/cache   available\n'
printf 'Mem:           100           0           0           0           0          80\n'
EOF
chmod +x "$TEMP_DIR/bin/df" "$TEMP_DIR/bin/free"

log_file="$TEMP_DIR/monitor.log"
ok_output="$(PATH="$TEMP_DIR/bin:$PATH" MONITOR_LOG="$log_file" "$SCRIPT" 50 20)" \
    || fail "usage at the configured limits should succeed"
assert_contains "$ok_output" "OK: usage is within both limits."
[[ ! -e "$log_file" ]] || fail "healthy usage should not create an alert log"

if breach_output="$(PATH="$TEMP_DIR/bin:$PATH" MONITOR_LOG="$log_file" "$SCRIPT" 40 10 2>&1)"; then
    fail "usage over both limits should fail"
fi
assert_contains "$breach_output" "disk / is 50% full"
assert_contains "$breach_output" "RAM is 20% in use"
assert_contains "$( < "$log_file" )" "ALERT:"

if "$SCRIPT" 0 75 >"$TEMP_DIR/invalid-output" 2>&1; then
    fail "zero storage limit should fail"
fi
assert_contains "$( < "$TEMP_DIR/invalid-output" )" "STORAGE_LIMIT must be a whole number"

echo "PASS: disk-memory-monitor.sh"
