#!/usr/bin/env bash
# =========================================================================
# Tests for bash/admin/provision-users.sh
#
# Nothing here needs root and nothing touches the real system. getent, id,
# useradd and chown are stateful FAKES that read and write a fake passwd
# file inside a temp directory; mkdir, chmod, grep and friends are the real
# tools working on that temp directory. The script runs with a PATH that
# contains only those, so results do not depend on what is installed.
#
# Fake behavior is controlled by environment variables:
#   FAKE_UID=1000        makes `id -u` report a non-root user
#   FAIL_USERADD=name    the fake useradd fails for that user
#
# Needs GNU coreutils (`stat -c`), i.e. Linux or WSL.
#
# The scripts are launched through `bash`, so the executable bit is not needed.
#
# Usage:
#   bash tests/bash/test_provision_users.sh               # all tests
#   bash tests/bash/test_provision_users.sh test_name ... # selected tests
# =========================================================================

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROVISION=$(cd "$SCRIPT_DIR/../../bash/admin" && pwd)/provision-users.sh
SELF=$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")

KEY_A='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAliceAliceAliceAliceAliceAliceAliceAlice alice@laptop'
KEY_A2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAliceSecondKeyAliceSecondKeyAliceSecond alice@phone'
KEY_B='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQBobBobBobBobBobBobBobBobBobBob bob@desktop'
KEY_C='ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCarolCarolCarol carol@work'

# =========================================================================
# Assertion and fixture helpers
# =========================================================================

OUT=""
RC=0

fail() {
    echo "  assertion failed: $*" >&2
    echo "  --- script output ---" >&2
    printf '%s\n' "$OUT" | sed 's/^/  | /' >&2
    echo "  --- fake tool calls ---" >&2
    sed 's/^/  | /' "$CALL_LOG" >&2 || true
    exit 1
}

assert_rc()      { [[ $RC -eq $1 ]] || fail "expected exit code $1, got $RC"; }
assert_out()     { grep -Fq -- "$1" <<<"$OUT" || fail "output does not contain: $1"; }
assert_not_out() { if grep -Fq -- "$1" <<<"$OUT"; then fail "output unexpectedly contains: $1"; fi; }

called()            { grep -Fqx -- "$1" "$CALL_LOG"; }
assert_called()     { called "$1" || fail "fake tool was not called: $1"; }
assert_not_called() { if called "$1"; then fail "fake tool should not have been called: $1"; fi; }
call_count()        { grep -c -- "^$1" "$CALL_LOG" || true; }
assert_no_calls()   { [[ ! -s $CALL_LOG ]] || fail "no changing tool should have been called"; }

home_of()    { echo "$TMP/home/$1"; }
auth_of()    { echo "$TMP/home/$1/.ssh/authorized_keys"; }
mode_of()    { stat -c %a "$1"; }
line_count() { grep -c '' "$1" || true; }
assert_file_has_line() { grep -Fxq -- "$2" "$1" || fail "$1 does not contain the line: $2"; }
assert_no_file()       { [[ ! -e $1 && ! -L $1 ]] || fail "should not exist: $1"; }

# write_list : write stdin to the list file
write_list() { cat > "$LIST"; }

# run ARGS... : run provision-users.sh with the isolated PATH
run() {
    RC=0
    OUT=$(PATH="$TMP/bin" bash "$PROVISION" "$@" </dev/null 2>&1) || RC=$?
}

# add_existing_user NAME [UID] : an account that already exists, with a home dir
add_existing_user() {
    echo "$1:x:${2:-1500}:${2:-1500}::$TMP/home/$1:/bin/bash" >> "$PASSWD_DB"
    mkdir -p "$TMP/home/$1"
}

setup_env() {
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    export CALL_LOG=$TMP/calls.log
    export PASSWD_DB=$TMP/passwd
    export GROUP_DB=$TMP/group
    export NEXT_UID_FILE=$TMP/next_uid
    export HOME_BASE=$TMP/home
    LIST=$TMP/users.txt
    mkdir -p "$TMP/bin" "$HOME_BASE"
    : > "$CALL_LOG"
    echo "www-data:x:33:33::$HOME_BASE/www-data:/usr/sbin/nologin" > "$PASSWD_DB"
    printf 'developers\nops\n' > "$GROUP_DB"
    echo 1000 > "$NEXT_UID_FILE"
    make_tools
}

make_tools() {
    local t
    for t in bash sh date cat basename grep tail mkdir chmod; do
        ln -s "$(command -v "$t")" "$TMP/bin/$t"
    done

    cat > "$TMP/bin/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then echo "${FAKE_UID:-0}"; exit 0; fi
exit 1
EOF

    cat > "$TMP/bin/getent" <<'EOF'
#!/bin/sh
case "$1" in
  passwd) grep "^$2:" "$PASSWD_DB" ;;
  group)  grep -x "$2" "$GROUP_DB" ;;
  *)      exit 2 ;;
esac
EOF

    cat > "$TMP/bin/useradd" <<'EOF'
#!/bin/sh
echo "useradd $*" >> "$CALL_LOG"
create=0; shell=/bin/sh; name=
while [ $# -gt 0 ]; do
  case "$1" in
    --create-home) create=1 ;;
    --shell) shell=$2; shift ;;
    --groups) shift ;;
    --) shift; name=$1; break ;;
  esac
  shift
done
if [ "$name" = "${FAIL_USERADD:-}" ]; then
  echo "useradd: fake failure for $name" >&2
  exit 1
fi
uid=$(cat "$NEXT_UID_FILE")
echo $((uid + 1)) > "$NEXT_UID_FILE"
echo "$name:x:$uid:$uid::$HOME_BASE/$name:$shell" >> "$PASSWD_DB"
if [ "$create" = 1 ]; then mkdir -p "$HOME_BASE/$name"; fi
exit 0
EOF

    cat > "$TMP/bin/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "$CALL_LOG"
exit 0
EOF

    chmod +x "$TMP/bin/id" "$TMP/bin/getent" "$TMP/bin/useradd" "$TMP/bin/chown"
}

# =========================================================================
# Tests: command line
# =========================================================================

test_help_needs_no_list_file() {
    setup_env
    run --help
    assert_rc 0
    assert_out "Usage:"
    assert_out "LIST_FILE"
    assert_out "does NOT do"
}

test_list_file_is_required() {
    setup_env
    run
    assert_rc 2
    assert_out "LIST_FILE is required"
}

test_unknown_option_exits_2() {
    setup_env
    write_list <<<"alice"
    run --bogus "$LIST"
    assert_rc 2
    assert_out "unknown option"
}

test_only_one_list_file() {
    setup_env
    write_list <<<"alice"
    run "$LIST" "$LIST"
    assert_rc 2
    assert_out "only one LIST_FILE"
}

test_option_without_value_exits_2() {
    setup_env
    write_list <<<"alice"
    run "$LIST" --group
    assert_rc 2
    assert_out "requires a value"
}

test_relative_shell_exits_2() {
    setup_env
    write_list <<<"alice"
    run --shell bash "$LIST"
    assert_rc 2
    assert_out "absolute path"
}

test_unreadable_list_exits_1() {
    setup_env
    run "$TMP/does-not-exist.txt"
    assert_rc 1
    assert_out "cannot read list file"
}

# =========================================================================
# Tests: list validation (everything is checked before anything changes)
# =========================================================================

test_invalid_entries_block_the_whole_run() {
    setup_env
    write_list <<EOF
alice $KEY_A
Bad_Name
root $KEY_A
bob not-a-key
carol $KEY_C
EOF
    run "$LIST"
    assert_rc 1
    assert_out "line 2: invalid username 'Bad_Name'"
    assert_out "line 3: refusing to provision 'root'"
    assert_out "line 4: 'bob'"
    assert_out "nothing was changed"
    assert_no_calls                                   # not even the valid users
    assert_no_file "$(home_of alice)"
}

test_private_keys_and_key_options_are_rejected() {
    setup_env
    write_list <<'EOF'
alice -----BEGIN OPENSSH PRIVATE KEY-----
bob command="/bin/true" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBobBobBobBobBob bob@x
EOF
    run "$LIST"
    assert_rc 1
    assert_out "line 1: 'alice'"
    assert_out "line 2: 'bob'"
    assert_no_calls
}

test_empty_list_exits_1() {
    setup_env
    printf '# only a comment\n\n' > "$LIST"
    run "$LIST"
    assert_rc 1
    assert_out "no users found"
}

test_comments_blank_lines_and_crlf_are_handled() {
    setup_env
    printf '# team list\r\n\r\nalice %s\r\n   \r\n# bob left\r\ncarol\r\n' "$KEY_A" > "$LIST"
    run --dry-run "$LIST"
    assert_rc 0
    assert_out "would run: useradd --create-home --shell /bin/bash -- alice"
    assert_out "would run: useradd --create-home --shell /bin/bash -- carol"
    assert_not_out "bob"
}

# =========================================================================
# Tests: preflight
# =========================================================================

test_must_be_root_to_apply() {
    setup_env
    export FAKE_UID=1000
    write_list <<<"alice $KEY_A"
    run "$LIST"
    assert_rc 1
    assert_out "must be run as root"
    assert_no_calls
}

test_dry_run_works_without_root() {
    setup_env
    export FAKE_UID=1000
    write_list <<<"alice $KEY_A"
    run --dry-run "$LIST"
    assert_rc 0
    assert_out "Dry run complete"
}

test_missing_tools_are_reported() {
    setup_env
    rm "$TMP/bin/useradd" "$TMP/bin/chown"
    write_list <<<"alice $KEY_A"
    run "$LIST"
    assert_rc 1
    assert_out "missing required tools"
    assert_out "useradd"
    assert_out "chown"
    run --dry-run "$LIST"                             # a dry run only needs getent
    assert_rc 0
}

test_unknown_group_exits_1() {
    setup_env
    write_list <<<"alice $KEY_A"
    run --group nope "$LIST"
    assert_rc 1
    assert_out "group does not exist: nope"
    assert_no_calls
}

# =========================================================================
# Tests: dry run
# =========================================================================

test_dry_run_changes_nothing() {
    setup_env
    add_existing_user bob
    write_list <<EOF
alice $KEY_A
bob $KEY_B
EOF
    run --dry-run "$LIST"
    assert_rc 0
    assert_no_calls
    assert_no_file "$(home_of alice)"
    assert_no_file "$(auth_of bob)"                   # even for an existing user
    assert_out "[dry-run] would run: useradd --create-home --shell /bin/bash -- alice"
    assert_out "[dry-run] would add key ssh-ed25519"
    assert_out "[dry-run] would add key ssh-rsa"
    assert_out "Nothing was changed"
    assert_not_out "Done:"
}

# =========================================================================
# Tests: creating users and installing keys
# =========================================================================

test_creates_user_and_installs_key_with_safe_permissions() {
    setup_env
    write_list <<<"alice $KEY_A"
    run "$LIST"
    assert_rc 0
    assert_called "useradd --create-home --shell /bin/bash -- alice"
    assert_file_has_line "$(auth_of alice)" "$KEY_A"
    [[ $(mode_of "$(home_of alice)/.ssh") == 700 ]] || fail ".ssh must be mode 700"
    [[ $(mode_of "$(auth_of alice)") == 600 ]] || fail "authorized_keys must be mode 600"
    assert_called "chown -- alice: $(home_of alice)/.ssh"
    assert_called "chown -- alice: $(auth_of alice)"
    assert_out "1 created"
    assert_out "1 key(s) added"
}

test_never_sets_passwords_or_generates_private_keys() {
    setup_env
    write_list <<<"alice $KEY_A"
    run "$LIST"
    assert_rc 0
    if grep -Eq 'passwd|chage|ssh-keygen|chpasswd' "$CALL_LOG"; then
        fail "password or key-generation tools must never be called"
    fi
    if compgen -G "$(home_of alice)/.ssh/id_*" >/dev/null; then
        fail "no private key may be created on the server"
    fi
}

test_shell_and_group_options_reach_useradd() {
    setup_env
    write_list <<<"alice $KEY_A"
    run --shell /bin/sh --group developers --group ops "$LIST"
    assert_rc 0
    assert_called "useradd --create-home --shell /bin/sh --groups developers,ops -- alice"
}

test_user_without_key_gets_a_notice() {
    setup_env
    write_list <<<"carol"
    run "$LIST"
    assert_rc 0
    assert_called "useradd --create-home --shell /bin/bash -- carol"
    assert_out "cannot log in over SSH yet"
    assert_no_file "$(auth_of carol)"
}

test_several_keys_for_one_user() {
    setup_env
    write_list <<EOF
alice $KEY_A
alice $KEY_A2
EOF
    run "$LIST"
    assert_rc 0
    assert_file_has_line "$(auth_of alice)" "$KEY_A"
    assert_file_has_line "$(auth_of alice)" "$KEY_A2"
    [[ $(line_count "$(auth_of alice)") -eq 2 ]] || fail "expected exactly 2 keys"
    [[ $(call_count useradd) -eq 1 ]] || fail "the user must be created once, not once per line"
}

test_duplicate_key_lines_are_added_once() {
    setup_env
    write_list <<EOF
alice $KEY_A
alice $KEY_A
EOF
    run "$LIST"
    assert_rc 0
    [[ $(line_count "$(auth_of alice)") -eq 1 ]] || fail "duplicate key was written twice"
}

# =========================================================================
# Tests: existing users and re-runs
# =========================================================================

test_rerun_is_idempotent() {
    setup_env
    write_list <<<"alice $KEY_A"
    run "$LIST"
    assert_rc 0
    run "$LIST"
    assert_rc 0
    assert_out "already exists"
    assert_out "already present"
    assert_out "0 created"
    [[ $(call_count useradd) -eq 1 ]] || fail "second run must not call useradd again"
    [[ $(line_count "$(auth_of alice)") -eq 1 ]] || fail "key was added twice"
}

test_existing_user_only_gets_missing_keys() {
    setup_env
    add_existing_user alice
    mkdir -p "$(home_of alice)/.ssh"
    echo "$KEY_A" > "$(auth_of alice)"
    write_list <<EOF
alice $KEY_A
alice $KEY_A2
EOF
    run "$LIST"
    assert_rc 0
    assert_not_called "useradd"
    [[ $(line_count "$(auth_of alice)") -eq 2 ]] || fail "expected exactly 2 keys"
    assert_file_has_line "$(auth_of alice)" "$KEY_A2"
    assert_out "1 key(s) added, 1 already present"
}

test_missing_trailing_newline_does_not_corrupt_keys() {
    setup_env
    add_existing_user alice
    mkdir -p "$(home_of alice)/.ssh"
    printf '%s' "$KEY_B" > "$(auth_of alice)"         # no trailing newline
    write_list <<<"alice $KEY_A"
    run "$LIST"
    assert_rc 0
    assert_file_has_line "$(auth_of alice)" "$KEY_B"  # still its own intact line
    assert_file_has_line "$(auth_of alice)" "$KEY_A"
    [[ $(line_count "$(auth_of alice)") -eq 2 ]] || fail "keys were glued together"
}

# =========================================================================
# Tests: safety refusals
# =========================================================================

test_system_accounts_are_never_modified() {
    setup_env
    write_list <<<"www-data $KEY_A"
    run "$LIST"
    assert_rc 1
    assert_out "refusing to modify an existing system account (uid 33)"
    assert_no_calls
    assert_no_file "$(auth_of www-data)"
}

test_symlinked_ssh_dir_is_refused() {
    setup_env
    add_existing_user alice
    mkdir -p "$TMP/elsewhere"
    ln -s "$TMP/elsewhere" "$(home_of alice)/.ssh"
    write_list <<<"alice $KEY_A"
    run "$LIST"
    assert_rc 1
    assert_out "symlink"
    assert_no_file "$TMP/elsewhere/authorized_keys"
}

test_symlinked_authorized_keys_is_refused() {
    setup_env
    add_existing_user alice
    mkdir -p "$(home_of alice)/.ssh"
    ln -s "$TMP/victim" "$(auth_of alice)"
    write_list <<<"alice $KEY_A"
    run "$LIST"
    assert_rc 1
    assert_out "symlink"
    assert_no_file "$TMP/victim"
}

test_existing_user_without_home_fails_cleanly() {
    setup_env
    echo "alice:x:1500:1500::$TMP/home/nowhere:/bin/bash" >> "$PASSWD_DB"
    write_list <<<"alice $KEY_A"
    run "$LIST"
    assert_rc 1
    assert_out "home directory"
    assert_no_calls
}

test_one_failure_does_not_stop_the_others() {
    setup_env
    export FAIL_USERADD=bob
    write_list <<EOF
alice $KEY_A
bob $KEY_B
carol $KEY_C
EOF
    run "$LIST"
    assert_rc 1
    assert_out "bob: useradd failed"
    assert_out "2 created"
    assert_out "1 failed"
    assert_file_has_line "$(auth_of alice)" "$KEY_A"
    assert_file_has_line "$(auth_of carol)" "$KEY_C"
    assert_no_file "$(auth_of bob)"
}

# =========================================================================
# Runner
# =========================================================================

if [[ ${1:-} == --run ]]; then
    # Child mode: run a single test with strict error handling.
    set -Eeuo pipefail
    "$2"
    exit 0
fi

tests=("$@")
if (( ${#tests[@]} == 0 )); then
    mapfile -t tests < <(declare -F | awk '$3 ~ /^test_/ {print $3}')
fi

passed=0
failed=0
for t in "${tests[@]}"; do
    if output=$(bash "$SELF" --run "$t" 2>&1); then
        echo "PASS  $t"
        passed=$((passed + 1))
    else
        echo "FAIL  $t"
        printf '%s\n' "$output" | sed 's/^/      /'
        failed=$((failed + 1))
    fi
done

echo
echo "$passed passed, $failed failed"
if (( failed > 0 )); then
    exit 1
fi
