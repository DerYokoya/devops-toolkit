#!/usr/bin/env bash
# =========================================================================
# Tests for bash/deployment/deploy.sh
#
# Every test runs in its own bash process against a throwaway git repo with
# a local bare "origin". npm, db-migrate, pm2 and curl are FAKES that only
# append their arguments to a call log, so nothing real is installed,
# migrated or restarted. The deploy script runs with a PATH that contains
# only the fakes plus the few real tools it needs, so the tests behave the
# same whether or not you have npm or pm2 installed.
#
# Fake behavior is controlled by environment variables:
#   FAIL_TOOLS=npm,pm2   these fakes exit 1
#   CURL_FAILS=N         the fake curl fails its first N calls
#
# Usage:
#   bash tests/bash/test_deploy.sh               # all tests
#   bash tests/bash/test_deploy.sh test_name ... # selected tests
# =========================================================================

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY=$(cd "$SCRIPT_DIR/../../bash/deployment" && pwd)/deploy.sh
SELF=$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")

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
assert_rc_not0() { [[ $RC -ne 0 ]] || fail "expected a non-zero exit code"; }
assert_out()     { grep -Fq -- "$1" <<<"$OUT" || fail "output does not contain: $1"; }
assert_not_out() { if grep -Fq -- "$1" <<<"$OUT"; then fail "output unexpectedly contains: $1"; fi; }

called()          { grep -Fqx -- "$1" "$CALL_LOG"; }
assert_called()   { called "$1" || fail "fake tool was not called: $1"; }
assert_not_called() { if called "$1"; then fail "fake tool should not have been called: $1"; fi; }
call_count()      { grep -c -- "^$1" "$CALL_LOG" || true; }
assert_no_calls() { [[ ! -s $CALL_LOG ]] || fail "no fake tool should have been called"; }

# assert_order "first call" "second call": both present, first logged before second
assert_order() {
    local a b
    a=$(grep -nFx -- "$1" "$CALL_LOG" | head -1 | cut -d: -f1 || true)
    b=$(grep -nFx -- "$2" "$CALL_LOG" | head -1 | cut -d: -f1 || true)
    [[ -n $a && -n $b ]] || fail "missing call(s) for order check: '$1' / '$2'"
    (( a < b )) || fail "'$1' should run before '$2'"
}

head_sha() { git -C "$WORK" rev-parse HEAD; }

# run ARGS... : run deploy.sh inside the work repo with the isolated PATH
run() {
    RC=0
    OUT=$(cd "$WORK" && PATH="$TMP/bin" "$DEPLOY" "$@" </dev/null 2>&1) || RC=$?
}

setup_env() {
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
    export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
    export GIT_CEILING_DIRECTORIES=$TMP
    export DEPLOY_LOCK_DIR=$TMP/locks
    export CALL_LOG=$TMP/calls.log
    mkdir -p "$TMP/bin" "$DEPLOY_LOCK_DIR"
    : > "$CALL_LOG"
    make_tools
}

make_tools() {
    local t
    # Real tools the deploy script itself needs.
    for t in bash sh git flock date sleep; do
        ln -s "$(command -v "$t")" "$TMP/bin/$t"
    done
    # Fakes that record their call.
    for t in npm db-migrate pm2; do
        cat > "$TMP/bin/$t" <<'EOF'
#!/bin/sh
name=$(basename "$0")
echo "$name $*" >> "$CALL_LOG"
case ",${FAIL_TOOLS:-}," in
  *",$name,"*) echo "fake $name failing on request" >&2; exit 1 ;;
esac
exit 0
EOF
        chmod +x "$TMP/bin/$t"
    done
    cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$CALL_LOG"
n=$(cat "$CALL_LOG.curl" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$CALL_LOG.curl"
if [ "$n" -le "${CURL_FAILS:-0}" ]; then
  echo "fake curl failing" >&2
  exit 22
fi
exit 0
EOF
    chmod +x "$TMP/bin/curl"
}

# commit MESSAGE : commit a new unique file in the current directory
commit() {
    printf '%s\n' "$1" > "file_${1//[^A-Za-z0-9]/_}.txt"
    git add -A
    git commit -q -m "$1"
}

# Work repo on main, with an up-to-date bare origin and a second clone
# ("other") used to push new upstream commits.
setup_repo() {
    setup_env
    ORIGIN=$TMP/origin.git
    WORK=$TMP/work
    OTHER=$TMP/other
    git -c init.defaultBranch=main init -q --bare "$ORIGIN"
    git -c init.defaultBranch=main init -q "$WORK"
    cd "$WORK"
    git remote add origin "$ORIGIN"
    commit "initial"
    git push -q -u origin main
    git clone -q "$ORIGIN" "$OTHER" 2>/dev/null
    cd "$WORK"
}

# push_upstream MESSAGE [BRANCH] : push a new commit to origin from the other clone
push_upstream() {
    git -C "$OTHER" checkout -q "${2:-main}"
    (cd "$OTHER" && commit "$1" && git push -q origin "${2:-main}")
    UPSTREAM_SHA=$(git -C "$OTHER" rev-parse HEAD)
}

# =========================================================================
# Tests: command line
# =========================================================================

test_help_works_outside_a_repo() {
    setup_env
    WORK=$TMP
    run --help
    assert_rc 0
    assert_out "Usage:"
    assert_out "--app NAME"
    assert_no_calls
}

test_app_is_required() {
    setup_repo
    run
    assert_rc 2
    assert_out "--app is required"
}

test_unknown_option_exits_2() {
    setup_repo
    run --app myapp --bogus
    assert_rc 2
    assert_out "unknown argument"
}

test_option_without_value_exits_2() {
    setup_repo
    run --app
    assert_rc 2
    assert_out "requires a value"
}

test_bad_app_name_exits_2() {
    setup_repo
    run --app '../evil'
    assert_rc 2
    run --app 'a b'
    assert_rc 2
}

test_option_like_branch_or_remote_exits_2() {
    setup_repo
    run --app myapp --branch --force
    assert_rc 2
    run --app myapp --remote -x
    assert_rc 2
}

test_bad_health_numbers_exit_2() {
    setup_repo
    run --app myapp --health-retries 0
    assert_rc 2
    run --app myapp --health-retries abc
    assert_rc 2
    run --app myapp --health-interval -1
    assert_rc 2
}

# =========================================================================
# Tests: preflight (nothing may run or change when preflight fails)
# =========================================================================

test_missing_tools_are_all_reported() {
    setup_repo
    rm "$TMP/bin/pm2" "$TMP/bin/db-migrate"
    run --app myapp
    assert_rc 1
    assert_out "missing required tools"
    assert_out "db-migrate"
    assert_out "pm2"
    assert_no_calls
}

test_curl_required_only_with_health_url() {
    setup_repo
    rm "$TMP/bin/curl"
    run --app myapp --dry-run
    assert_rc 0
    run --app myapp --dry-run --health-url http://localhost/health
    assert_rc 1
    assert_out "curl"
}

test_outside_repo_exits_1() {
    setup_env
    mkdir "$TMP/plain"
    WORK=$TMP/plain
    run --app myapp
    assert_rc 1
    assert_out "not inside a git work tree"
    assert_no_calls
}

test_unknown_remote_exits_1() {
    setup_repo
    run --app myapp --remote nope
    assert_rc 1
    assert_out "remote 'nope' does not exist"
    assert_no_calls
}

test_detached_head_exits_1() {
    setup_repo
    git -C "$WORK" checkout -q --detach
    run --app myapp
    assert_rc 1
    assert_out "detached"
    assert_no_calls
}

test_wrong_branch_exits_1() {
    setup_repo
    run --app myapp --branch release
    assert_rc 1
    assert_out "checked-out branch is 'main' but --branch is 'release'"
    assert_no_calls
}

test_dirty_working_tree_exits_1() {
    setup_repo
    echo "local edit" >> "$WORK/file_initial.txt"
    local before; before=$(head_sha)
    run --app myapp
    assert_rc 1
    assert_out "uncommitted changes"
    assert_no_calls
    [[ $(head_sha) == "$before" ]] || fail "HEAD must not move"
}

test_untracked_files_do_not_block_deploy() {
    setup_repo
    echo "scratch" > "$WORK/notes.tmp"
    run --app myapp
    assert_rc 0
}

test_concurrent_deploy_is_refused() {
    setup_repo
    local lock=$DEPLOY_LOCK_DIR/deploy-myapp.lock
    flock "$lock" sleep 5 &
    local holder=$!
    for _ in {1..50}; do
        if ! flock --nonblock "$lock" true 2>/dev/null; then break; fi
        sleep 0.1
    done
    run --app myapp
    kill "$holder" 2>/dev/null || true
    assert_rc 1
    assert_out "already running"
    assert_no_calls
}

test_different_apps_do_not_share_a_lock() {
    setup_repo
    local lock=$DEPLOY_LOCK_DIR/deploy-otherapp.lock
    flock "$lock" sleep 5 &
    local holder=$!
    for _ in {1..50}; do
        if ! flock --nonblock "$lock" true 2>/dev/null; then break; fi
        sleep 0.1
    done
    run --app myapp
    kill "$holder" 2>/dev/null || true
    assert_rc 0
}

# =========================================================================
# Tests: successful deploys
# =========================================================================

test_happy_path_runs_steps_in_order() {
    setup_repo
    local before; before=$(head_sha)
    push_upstream "new feature"
    run --app myapp
    assert_rc 0
    [[ $(head_sha) == "$UPSTREAM_SHA" ]] || fail "work tree should be at the new upstream commit"
    assert_called "npm ci --omit=dev"
    assert_called "db-migrate up"
    assert_called "pm2 reload myapp"
    assert_order "npm ci --omit=dev" "db-migrate up"
    assert_order "db-migrate up" "pm2 reload myapp"       # migrate BEFORE reload
    assert_out "Deployed myapp: ${before:0:7} -> ${UPSTREAM_SHA:0:7}"
    assert_out "git reset --hard $before"
}

test_deploy_never_runs_audit_fix_or_startup() {
    setup_repo
    run --app myapp
    assert_rc 0
    assert_not_called "npm audit fix"
    assert_not_called "pm2 startup"
}

test_already_up_to_date_still_deploys() {
    setup_repo
    run --app myapp
    assert_rc 0
    assert_called "pm2 reload myapp"
}

test_branch_defaults_to_current_branch() {
    setup_repo
    git -C "$WORK" checkout -q -b release
    git -C "$WORK" push -q -u origin release
    push_upstream "release only change" release
    run --app myapp
    assert_rc 0
    assert_out "branch=release"
    [[ $(head_sha) == "$UPSTREAM_SHA" ]] || fail "should have fast-forwarded the release branch"
}

# =========================================================================
# Tests: dry run
# =========================================================================

test_dry_run_changes_and_runs_nothing() {
    setup_repo
    local before; before=$(head_sha)
    push_upstream "new feature"
    run --app myapp --dry-run --health-url http://localhost:3000/health
    assert_rc 0
    assert_no_calls
    [[ $(head_sha) == "$before" ]] || fail "dry run must not move HEAD"
    assert_out "[dry-run] would run: git fetch origin main"
    assert_out "[dry-run] would run: git merge --ff-only FETCH_HEAD"
    assert_out "[dry-run] would run: npm ci --omit=dev"
    assert_out "[dry-run] would run: db-migrate up"
    assert_out "[dry-run] would run: pm2 reload myapp"
    assert_out "[dry-run] would check http://localhost:3000/health"
    assert_out "Dry run complete"
    assert_not_out "Deployed"
}

test_dry_run_still_runs_preflight() {
    setup_repo
    echo "local edit" >> "$WORK/file_initial.txt"
    run --app myapp --dry-run
    assert_rc 1
    assert_out "uncommitted changes"
}

# =========================================================================
# Tests: failures (stop at the first failure, print how to roll back)
# =========================================================================

test_diverged_history_stops_before_any_change() {
    setup_repo
    (cd "$WORK" && commit "local only commit")
    push_upstream "upstream only commit"
    local before; before=$(head_sha)
    run --app myapp
    assert_rc_not0
    assert_out "DEPLOY FAILED during: fast-forward"
    assert_no_calls                                       # no npm, migrations or reload
    [[ $(head_sha) == "$before" ]] || fail "HEAD must not move on a failed fast-forward"
    assert_not_out "git reset --hard"                     # nothing changed, no rollback needed
}

test_npm_failure_stops_before_migrations() {
    setup_repo
    local before; before=$(head_sha)
    push_upstream "new feature"
    RC=0
    OUT=$(cd "$WORK" && FAIL_TOOLS=npm PATH="$TMP/bin" "$DEPLOY" --app myapp </dev/null 2>&1) || RC=$?
    assert_rc_not0
    assert_out "DEPLOY FAILED during: install dependencies"
    assert_out "git reset --hard $before"
    assert_not_out "db-migrate down"                      # no migration ran yet
    assert_not_called "db-migrate up"
    assert_not_called "pm2 reload myapp"
}

test_migration_failure_leaves_old_app_running() {
    setup_repo
    local before; before=$(head_sha)
    push_upstream "new feature"
    RC=0
    OUT=$(cd "$WORK" && FAIL_TOOLS=db-migrate PATH="$TMP/bin" "$DEPLOY" --app myapp </dev/null 2>&1) || RC=$?
    assert_rc_not0
    assert_out "DEPLOY FAILED during: run migrations"
    assert_out "git reset --hard $before"
    assert_out "db-migrate down"                          # DB note shown
    assert_not_called "pm2 reload myapp"                  # the running app was never restarted
}

test_reload_failure_prints_rollback() {
    setup_repo
    local before; before=$(head_sha)
    push_upstream "new feature"
    RC=0
    OUT=$(cd "$WORK" && FAIL_TOOLS=pm2 PATH="$TMP/bin" "$DEPLOY" --app myapp </dev/null 2>&1) || RC=$?
    assert_rc_not0
    assert_out "DEPLOY FAILED during: reload myapp"
    assert_out "git reset --hard $before && npm ci --omit=dev && pm2 reload myapp"
    assert_out "db-migrate down"
}

# =========================================================================
# Tests: health check
# =========================================================================

test_no_health_url_skips_check() {
    setup_repo
    run --app myapp
    assert_rc 0
    assert_out "skipping the health check"
    [[ $(call_count curl) -eq 0 ]] || fail "curl must not be called"
}

test_health_check_passes() {
    setup_repo
    run --app myapp --health-url http://localhost:3000/health
    assert_rc 0
    assert_out "Health check passed"
    assert_order "pm2 reload myapp" "curl --fail --silent --show-error --max-time 5 --output /dev/null http://localhost:3000/health"
}

test_health_check_retries_until_up() {
    setup_repo
    RC=0
    OUT=$(cd "$WORK" && CURL_FAILS=2 PATH="$TMP/bin" "$DEPLOY" --app myapp \
        --health-url http://localhost:3000/health --health-interval 0 </dev/null 2>&1) || RC=$?
    assert_rc 0
    [[ $(call_count curl) -eq 3 ]] || fail "expected 3 curl attempts, got $(call_count curl)"
    assert_out "attempt 3/10"
}

test_health_check_failure_fails_the_deploy() {
    setup_repo
    local before; before=$(head_sha)
    RC=0
    OUT=$(cd "$WORK" && CURL_FAILS=99 PATH="$TMP/bin" "$DEPLOY" --app myapp \
        --health-url http://localhost:3000/health --health-retries 3 --health-interval 0 </dev/null 2>&1) || RC=$?
    assert_rc 1
    [[ $(call_count curl) -eq 3 ]] || fail "expected exactly 3 curl attempts, got $(call_count curl)"
    assert_out "Health check failed after 3 attempts"
    assert_out "DEPLOY FAILED during: health check"
    assert_out "git reset --hard $before"
    assert_not_out "Deployed myapp"
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