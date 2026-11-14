#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/bash/deployment/env-check.sh"

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
assert_contains "$help_output" "Required .env variables:"

if invalid_output="$("$SCRIPT" --invalid-option 2>&1)"; then
    fail "unknown options should fail"
fi
assert_contains "$invalid_output" "Unknown option: --invalid-option"

echo "PASS: env-check.sh"
