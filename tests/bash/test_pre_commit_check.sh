#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/bash/git/pre-commit-check.sh"
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
assert_contains "$help_output" "--all"

if invalid_output="$(bash "$SCRIPT" --invalid-option 2>&1)"; then
    fail "unknown options should fail"
fi
assert_contains "$invalid_output" "Unknown argument: --invalid-option"

if outside_git_output="$(cd "$TEMP_DIR" && bash "$SCRIPT" 2>&1)"; then
    fail "running outside a Git repository should fail"
fi
assert_contains "$outside_git_output" "not inside a git repository"

echo "PASS: pre-commit-check.sh"
