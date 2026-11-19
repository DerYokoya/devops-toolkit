#!/usr/bin/env bash
# =========================================================================
# Tests for bash/git/stale-branch-cleaner.sh
#
# Every test runs in its own bash process against a throwaway repository
# with a local bare repo acting as "origin". Nothing touches your real
# repositories or your git config.
#
# Usage:
#   bash tests/bash/test_stale_branch_cleaner.sh               # all tests
#   bash tests/bash/test_stale_branch_cleaner.sh test_name ... # selected tests
# =========================================================================

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLEANER=$(cd "$SCRIPT_DIR/../../bash/git" && pwd)/stale-branch-cleaner.sh
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
    exit 1
}

assert_rc()      { [[ $RC -eq $1 ]] || fail "expected exit code $1, got $RC"; }
assert_out()     { grep -Fq -- "$1" <<<"$OUT" || fail "output does not contain: $1"; }
assert_not_out() { if grep -Fq -- "$1" <<<"$OUT"; then fail "output unexpectedly contains: $1"; fi; }

# A report line looks like: "  local  feature/x   abc1234  2026-01-01"
listed()             { grep -Eq "^ +$1 +$2( |\$)" <<<"$OUT"; }
assert_listed()      { listed "$1" "$2" || fail "$1 branch not listed: $2"; }
assert_not_listed()  { if listed "$1" "$2"; then fail "$1 branch should not be listed: $2"; fi; }

local_has()        { git -C "$WORK" show-ref --verify --quiet "refs/heads/$1"; }
remote_has()       { git --git-dir="$ORIGIN" show-ref --verify --quiet "refs/heads/$1"; }
assert_local()     { local_has "$1" || fail "local branch missing: $1"; }
assert_no_local()  { if local_has "$1"; then fail "local branch should be gone: $1"; fi; }
assert_remote()    { remote_has "$1" || fail "remote branch missing: $1"; }
assert_no_remote() { if remote_has "$1"; then fail "remote branch should be gone: $1"; fi; }

# run ARGS...        : run the cleaner inside the work repo, stdin closed
# run_in INPUT ARGS  : same, but feed INPUT (printf %b escapes) on stdin
run() {
    RC=0
    OUT=$(cd "$WORK" && "$CLEANER" "$@" </dev/null 2>&1) || RC=$?
}
run_in() {
    local input=$1
    shift
    RC=0
    OUT=$(cd "$WORK" && printf '%b' "$input" | "$CLEANER" "$@" 2>&1) || RC=$?
}

setup_env() {
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
    export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
    export GIT_CEILING_DIRECTORIES=$TMP
}

# commit_at MONTHS_AGO MESSAGE : commit with a backdated author/committer date
commit_at() {
    local d
    d=$(date -d "$1 months ago" +%Y-%m-%dT%H:%M:%S)
    printf '%s\n' "$2" > "file_${2//[^A-Za-z0-9]/_}.txt"
    git add -A
    GIT_AUTHOR_DATE=$d GIT_COMMITTER_DATE=$d git commit -q -m "$2"
}

# make_branch NAME MONTHS_AGO [push|nopush] : one backdated commit on top of main
make_branch() {
    git checkout -q -b "$1" main
    commit_at "$2" "work on $1"
    if [[ ${3:-push} == push ]]; then
        git push -q origin "$1"
    fi
    git checkout -q main
}

merge_branch() {
    git merge -q --no-ff -m "merge $1" "$1"
    git push -q origin main
}

# Minimal repo: bare origin + work clone on main, origin/HEAD set.
setup_repo() {
    setup_env
    ORIGIN=$TMP/origin.git
    WORK=$TMP/work
    git -c init.defaultBranch=main init -q --bare "$ORIGIN"
    git -c init.defaultBranch=main init -q "$WORK"
    cd "$WORK"
    git remote add origin "$ORIGIN"
    commit_at 0 "initial"
    git push -q -u origin main
    git remote set-head origin main
}

# Repo with every case we care about (default threshold is 12 months):
#
#   feature/merged-old     merged into main, last commit 24 months ago
#   feature/merged-recent  merged into main, last commit today
#   feature/stale          NOT merged, 24 months old
#   feature/production     NOT merged, 24 months old (name ends in "production":
#                          the old regex wrongly protected this; now it is a
#                          normal branch)
#   feature/fresh          NOT merged, new           -> keep
#   develop                NOT merged, 24 months old -> protected, keep
#   local-unpushed         NOT merged, 24 months old, local only
#   at-main                points exactly at main    -> keep (new branch)
setup_standard() {
    setup_repo
    make_branch feature/merged-old 24
    merge_branch feature/merged-old
    make_branch feature/merged-recent 0
    merge_branch feature/merged-recent
    make_branch feature/stale 24
    make_branch feature/production 24
    make_branch feature/fresh 0
    make_branch develop 24
    make_branch local-unpushed 24 nopush
    git branch at-main main          # created last: same commit as main's tip
    git push -q origin at-main
}

# =========================================================================
# Tests: command line
# =========================================================================

test_help_exits_zero() {
    setup_repo
    run --help
    assert_rc 0
    assert_out "Usage:"
    assert_out "DRY RUN"
}

test_unknown_option_exits_2() {
    setup_repo
    run --bogus
    assert_rc 2
    assert_out "unknown argument"
}

test_positional_argument_exits_2() {
    setup_repo
    run 6
    assert_rc 2
}

test_invalid_months_exits_2() {
    setup_repo
    run --months abc
    assert_rc 2
    run --months 0
    assert_rc 2
    run --months -3
    assert_rc 2
    run --months
    assert_rc 2
    assert_out "requires a value"
}

test_conflicting_scopes_exit_2() {
    setup_repo
    run --local-only --remote-only
    assert_rc 2
}

test_outside_repo_exits_1() {
    setup_env
    mkdir "$TMP/plain"
    WORK=$TMP/plain
    run
    assert_rc 1
    assert_out "not inside a git work tree"
}

test_missing_base_exits_1() {
    setup_standard
    run --base does-not-exist
    assert_rc 1
    assert_out "not found"
}

# =========================================================================
# Tests: what gets listed
# =========================================================================

test_nothing_to_do() {
    setup_repo
    run
    assert_rc 0
    assert_out "No stale or merged branches found"
}

test_default_is_dry_run_and_deletes_nothing() {
    setup_standard
    run
    assert_rc 0
    assert_out "Dry run: nothing was deleted"
    for b in feature/merged-old feature/merged-recent feature/stale \
             feature/production feature/fresh develop at-main; do
        assert_local "$b"
        assert_remote "$b"
    done
    assert_local local-unpushed
}

test_lists_merged_and_stale_branches() {
    setup_standard
    run
    assert_rc 0
    for scope in local remote; do
        assert_listed "$scope" feature/merged-old
        assert_listed "$scope" feature/merged-recent   # merged counts at any age
        assert_listed "$scope" feature/stale
        assert_listed "$scope" feature/production      # not protected by suffix
    done
    assert_listed local local-unpushed
    assert_out "Merged into origin/main:"
    assert_out "Not merged, but untouched for"
}

test_never_lists_protected_fresh_or_unmoved_branches() {
    setup_standard
    run
    for scope in local remote; do
        assert_not_listed "$scope" main
        assert_not_listed "$scope" develop            # protected
        assert_not_listed "$scope" feature/fresh      # unmerged but recent
        assert_not_listed "$scope" at-main            # same commit as main
        assert_not_listed "$scope" HEAD               # origin/HEAD symref
    done
}

test_unpushed_local_branch_is_flagged() {
    setup_standard
    run
    grep -Eq "^ +local +local-unpushed .*UNPUSHED" <<<"$OUT" || fail "no UNPUSHED flag on local-unpushed"
    if grep -Eq "^ +local +feature/stale .*UNPUSHED" <<<"$OUT"; then
        fail "feature/stale exists on the remote, it must not be flagged UNPUSHED"
    fi
}

test_months_threshold_is_respected() {
    setup_standard
    run --months 36                                   # 24-month-old branches are not stale yet
    assert_rc 0
    assert_not_listed remote feature/stale
    assert_not_listed local local-unpushed
    assert_listed remote feature/merged-old           # merged regardless of age
}

test_protect_option_keeps_branch() {
    setup_standard
    run --protect feature/stale --protect feature/merged-old
    assert_not_listed local feature/stale
    assert_not_listed remote feature/stale
    assert_not_listed remote feature/merged-old
    assert_listed remote feature/production
}

test_stale_tip_is_judged_by_tip_date_not_history() {
    # feature/stale was cut from a recent main, so `git log --since` on it would
    # see recent commits and call it fresh. The tip date must be what counts.
    setup_standard
    run
    assert_listed remote feature/stale
}

test_worktree_branch_is_protected() {
    setup_standard
    git -C "$WORK" worktree add -q "$TMP/wt" feature/stale
    run
    assert_not_listed local feature/stale
    assert_not_listed remote feature/stale
    assert_listed remote feature/production
}

test_base_falls_back_to_main_without_origin_head() {
    setup_standard
    git -C "$WORK" remote set-head origin -d
    run
    assert_rc 0
    assert_out "Base branch: origin/main"
    assert_listed remote feature/merged-old
}

test_fetch_prunes_branches_deleted_on_the_remote() {
    setup_standard
    git --git-dir="$ORIGIN" branch -D feature/stale >/dev/null
    run --no-fetch
    assert_listed remote feature/stale                # stale tracking ref still on disk
    run
    assert_not_listed remote feature/stale            # fetch --prune dropped it
    assert_out "Fetching latest data"
}

test_local_only_without_remote() {
    setup_standard
    git -C "$WORK" remote remove origin
    run
    assert_rc 0
    assert_out "local branches only"
    assert_listed local feature/merged-old
    assert_not_listed remote feature/merged-old
}

# =========================================================================
# Tests: deleting
# =========================================================================

test_delete_with_yes_removes_the_right_branches() {
    setup_standard
    run --delete --yes
    assert_rc 0
    assert_out "Done:"
    for b in feature/merged-old feature/merged-recent feature/stale feature/production; do
        assert_no_local "$b"
        assert_no_remote "$b"
    done
    assert_no_local local-unpushed
    for b in main develop feature/fresh at-main; do
        assert_local "$b"
        assert_remote "$b"
    done
}

test_prompt_yes_deletes() {
    setup_standard
    run_in 'y\n' --delete
    assert_rc 0
    assert_out "[y/N]"
    assert_no_remote feature/stale
    assert_no_local feature/stale
}

test_prompt_no_keeps_everything() {
    setup_standard
    run_in 'n\n' --delete
    assert_rc 0
    assert_out "Aborted. Nothing was deleted."
    assert_remote feature/stale
    assert_local feature/stale
    assert_remote feature/merged-old
}

test_closed_stdin_counts_as_no() {
    setup_standard
    run --delete                                      # stdin is /dev/null, no --yes
    assert_rc 0
    assert_out "Aborted"
    assert_remote feature/stale
}

test_dry_run_flag_overrides_delete() {
    setup_standard
    run --delete --yes --dry-run
    assert_rc 0
    assert_out "Dry run"
    assert_remote feature/stale
    assert_local feature/stale
}

test_local_only_leaves_remote_alone() {
    setup_standard
    run --delete --yes --local-only
    assert_rc 0
    assert_no_local feature/stale
    assert_no_local feature/merged-old
    assert_remote feature/stale
    assert_remote feature/merged-old
}

test_remote_only_leaves_local_alone() {
    setup_standard
    run --delete --yes --remote-only
    assert_rc 0
    assert_no_remote feature/stale
    assert_no_remote feature/merged-old
    assert_local feature/stale
    assert_local feature/merged-old
    assert_local local-unpushed
}

test_failed_deletion_continues_and_exits_1() {
    setup_standard
    # The remote refuses to delete feature/merged-old (alphabetically first).
    cat > "$ORIGIN/hooks/pre-receive" <<'EOF'
#!/bin/sh
while read -r old new ref; do
  case "$new" in
    *[!0]*) ;;                                        # not a deletion
    *) if [ "$ref" = refs/heads/feature/merged-old ]; then
         echo "deletion refused by test hook" >&2
         exit 1
       fi ;;
  esac
done
exit 0
EOF
    chmod +x "$ORIGIN/hooks/pre-receive"

    run --delete --yes --remote-only
    assert_rc 1
    assert_out "FAILED to delete remote branch origin/feature/merged-old"
    assert_out "1 failed"
    assert_remote feature/merged-old                  # refused
    assert_no_remote feature/merged-recent            # the rest still went through
    assert_no_remote feature/stale
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
