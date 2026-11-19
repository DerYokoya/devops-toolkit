#!/usr/bin/env bash
# -E to ensure ERR trap is inherited by functions, command substitutions, and subshells
set -Eeuo pipefail
trap 'echo "$(date +%F_%T) ERROR: line $LINENO: command failed" >&2' ERR

# =========================================================================
# Stale branch cleaner
#   - fetches and prunes the remote first, so decisions use fresh data
#   - "merged":  the branch tip is already contained in the default branch
#                (a branch pointing exactly at the default branch tip is NOT
#                 treated as merged: it is usually a brand-new branch)
#   - "stale":   not merged, and its last commit is older than N months
#                (judged by the branch TIP date, not by reachable history)
#   - protected branches are never touched: main, master, develop,
#     development, production, the default branch, anything checked out in a
#     worktree, plus whatever --protect adds (exact names, not patterns)
#   - DRY RUN BY DEFAULT: nothing is deleted without --delete, and --delete
#     asks for confirmation unless --yes is also given
#
# Requires GNU date (Linux / WSL).
# =========================================================================

# --- Config --------------------------------------------------------------
MAX_BRANCH_AGE=12            # months
REMOTE=origin
BASE=""                      # default branch; auto-detected when empty
PROTECTED=(main master develop development production)
APPLY=0                      # 0 = dry run (default), 1 = delete
FORCE_DRY=0                  # --dry-run always wins over --delete
ASSUME_YES=0
DO_FETCH=1
SCOPE_LOCAL=1
SCOPE_REMOTE=1

# --- State (filled in while running) -------------------------------------
HAVE_REMOTE=0
BASE_REF=""
BASE_SHA=""
BASE_LABEL=""
CUTOFF=0
LOCAL_COUNT=0
REMOTE_COUNT=0
CANDIDATES=()                # kind<TAB>scope<TAB>name<TAB>sha<TAB>date<TAB>note

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Finds Git branches that are already merged into the default branch, or that
have had no commits for a number of months, and (optionally) deletes them.

By default this is a DRY RUN: it only lists what it would delete.

Options:
  -d, --delete       Actually delete the branches (asks for confirmation).
  -y, --yes          With --delete: skip the confirmation prompt (for cron/CI).
  -n, --dry-run      Only list branches. Wins over --delete.
  -m, --months N     Age threshold for unmerged branches (default: $MAX_BRANCH_AGE).
      --base NAME    Default branch to compare against (default: auto-detect).
      --remote NAME  Remote to use (default: origin).
      --protect NAME Never touch this branch (exact name). Repeatable.
      --local-only   Only consider local branches.
      --remote-only  Only consider remote branches.
      --no-fetch     Skip 'git fetch --prune' (use the data already on disk).
  -h, --help         Show this help message and exit.

Always protected: main master develop development production, the default
branch, and any branch checked out in a worktree (both its local and remote
copy).

Notes:
  - A branch that points exactly at the default branch tip is never reported
    as merged (it is usually a new branch with no commits yet).
  - Squash-merged branches are not detected as merged; they show up as stale
    once they are old enough.
  - Stale local branches that exist on no remote are flagged UNPUSHED:
    deleting them loses commits (recoverable only through the reflog).

Exit status:
  0    Finished (including dry runs, "nothing to do" and a declined prompt).
  1    Not a git repository, fetch/base lookup failed, or a deletion failed.
  2    Invalid command-line usage.

Examples (run from anywhere inside the repository):
  ./bash/git/stale-branch-cleaner.sh                   # dry run, 12 months
  ./bash/git/stale-branch-cleaner.sh -m 6              # dry run, 6 months
  ./bash/git/stale-branch-cleaner.sh --delete          # list, confirm, delete
  ./bash/git/stale-branch-cleaner.sh --delete --yes --local-only
EOF
}

# If a required tool is missing, exit with an install hint.
die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage_error() {
    echo "error: $*" >&2
    usage >&2
    exit 2
}

is_protected() {
    local p
    for p in "${PROTECTED[@]}"; do
    # if the branch name matches any of the protected names, return true
        if [[ $1 == "$p" ]]; then
            return 0
        fi
    done
    return 1
}

# =========================================================================
# Arguments
# =========================================================================
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)     usage; exit 0 ;;
            -n|--dry-run)  FORCE_DRY=1 ;;
            -d|--delete)   APPLY=1 ;;
            -y|--yes)      ASSUME_YES=1 ;;
            --no-fetch)    DO_FETCH=0 ;;
            --local-only)  SCOPE_REMOTE=0 ;;
            --remote-only) SCOPE_LOCAL=0 ;;
            -m|--months|--base|--remote|--protect)
                if (( $# < 2 )); then
                    usage_error "$1 requires a value"
                fi
                case "$1" in
                    -m|--months) MAX_BRANCH_AGE=$2 ;;
                    --base)      BASE=$2 ;;
                    --remote)    REMOTE=$2 ;;
                    --protect)   PROTECTED+=("$2") ;;
                esac
                shift
                ;;
            *) usage_error "unknown argument: $1" ;;
        esac
        shift
    done

    if (( ! SCOPE_LOCAL && ! SCOPE_REMOTE )); then
        usage_error "--local-only and --remote-only cannot be combined"
    fi
    if [[ ! $MAX_BRANCH_AGE =~ ^[0-9]+$ ]] || (( 10#$MAX_BRANCH_AGE < 1 )); then
        usage_error "--months must be a positive whole number"
    fi
    MAX_BRANCH_AGE=$((10#$MAX_BRANCH_AGE))
}

# =========================================================================
# Setup
# =========================================================================

# Work out which branch everything is compared against, and pin it to a SHA.
resolve_base() {
    local head_ref c

    if [[ -z $BASE ]] && (( HAVE_REMOTE )); then
        head_ref=$(git symbolic-ref --quiet --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null || true)
        BASE=${head_ref#"$REMOTE"/}
    fi
    if [[ -z $BASE ]]; then
        for c in main master; do
            if git show-ref --verify --quiet "refs/heads/$c" \
                || git show-ref --verify --quiet "refs/remotes/$REMOTE/$c"; then
                BASE=$c
                break
            fi
        done
    fi
    if [[ -z $BASE ]]; then
        die "cannot determine the default branch; pass --base NAME"
    fi

    # Prefer the remote copy: right after a fetch it is the most up to date.
    if (( HAVE_REMOTE )) && git show-ref --verify --quiet "refs/remotes/$REMOTE/$BASE"; then
        BASE_REF="refs/remotes/$REMOTE/$BASE"
        BASE_LABEL="$REMOTE/$BASE"
    elif git show-ref --verify --quiet "refs/heads/$BASE"; then
        BASE_REF="refs/heads/$BASE"
        BASE_LABEL=$BASE
    else
        die "base branch '$BASE' not found"
    fi

    BASE_SHA=$(git rev-parse --verify --quiet "$BASE_REF^{commit}")
    PROTECTED+=("$BASE")
}

# Branches checked out in any worktree (including this one) cannot be deleted.
protect_checked_out_branches() {
    local key val
    while read -r key val; do
        if [[ $key == branch ]]; then
            PROTECTED+=("${val#refs/heads/}")
        fi
    done < <(git worktree list --porcelain)
}

# scan_refs SCOPE REF_ROOT PREFIX_TO_STRIP
# Adds a CANDIDATES entry for every merged or stale branch under REF_ROOT.
scan_refs() {
    local scope=$1 root=$2 prefix=$3
    local ref sha ts name kind note

    while read -r ref sha ts; do
        name=${ref#"$prefix"}
        if [[ $name == HEAD ]]; then
            continue                      # e.g. refs/remotes/origin/HEAD
        fi
        if is_protected "$name"; then
            continue
        fi

        if [[ $sha != "$BASE_SHA" ]] && git merge-base --is-ancestor "$sha" "$BASE_SHA"; then
            kind=merged
        elif (( ts < CUTOFF )); then
            kind=stale
        else
            continue
        fi

        note=""
        if [[ $scope == local && $kind == stale ]] \
            && [[ -z $(git branch --remotes --contains "$sha") ]]; then
            note=unpushed
        fi

        CANDIDATES+=("$kind"$'\t'"$scope"$'\t'"$name"$'\t'"${sha:0:7}"$'\t'"$(date -d "@$ts" +%F)"$'\t'"$note")
        if [[ $scope == local ]]; then
            LOCAL_COUNT=$((LOCAL_COUNT + 1))
        else
            REMOTE_COUNT=$((REMOTE_COUNT + 1))
        fi
    done < <(git for-each-ref --format='%(refname) %(objectname) %(committerdate:unix)' "$root")
}

# =========================================================================
# Report, confirm, delete
# =========================================================================

print_report() {
    local kind entry k scope name sha date note header printed

    echo
    echo "Base branch: $BASE_LABEL"
    echo "Stale means: not merged and no commits since $(date -d "@$CUTOFF" +%F) ($MAX_BRANCH_AGE months)"

    for kind in merged stale; do
        printed=0
        if [[ $kind == merged ]]; then
            header="Merged into $BASE_LABEL:"
        else
            header="Not merged, but untouched for $MAX_BRANCH_AGE+ months:"
        fi
        for entry in "${CANDIDATES[@]}"; do
            IFS=$'\t' read -r k scope name sha date note <<<"$entry"
            if [[ $k != "$kind" ]]; then
                continue
            fi
            if (( ! printed )); then
                echo
                echo "$header"
                printed=1
            fi
            printf '  %-6s %-40s %s  %s%s\n' \
                "$scope" "$name" "$sha" "$date" "${note:+  [UNPUSHED COMMITS]}"
        done
    done
    echo
}

confirm() {
    local answer=""
    printf 'Delete %d local and %d remote branch(es)? Remote deletions cannot be undone by this script. [y/N] ' \
        "$LOCAL_COUNT" "$REMOTE_COUNT"
    read -r answer || answer=""
    [[ $answer == y || $answer == Y || $answer == yes ]]
}

# One failed deletion must not stop the rest, so every call sits in an `if`.
delete_candidates() {
    local entry kind scope name sha date note
    local deleted=0 failed=0

    for entry in "${CANDIDATES[@]}"; do
        IFS=$'\t' read -r kind scope name sha date note <<<"$entry"
        if [[ $scope == remote ]]; then
            if git push --quiet "$REMOTE" --delete "$name"; then
                echo "Deleted remote branch $REMOTE/$name"
                deleted=$((deleted + 1))
            else
                echo "FAILED to delete remote branch $REMOTE/$name" >&2
                failed=$((failed + 1))
            fi
        else
            # -D is safe here: merged/stale was already verified against the
            # base branch above, and 'git branch -d' would compare against
            # HEAD/upstream instead, which gives false refusals.
            if git branch -D -- "$name"; then
                deleted=$((deleted + 1))
            else
                echo "FAILED to delete local branch $name" >&2
                failed=$((failed + 1))
            fi
        fi
    done

    echo
    echo "Done: $deleted deleted, $failed failed."
    if (( failed > 0 )); then
        exit 1
    fi
}

# =========================================================================
# Main
# =========================================================================
main() {
    parse_args "$@"

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "not inside a git work tree"
    fi
    if (( FORCE_DRY )); then
        APPLY=0
    fi

    if git remote get-url "$REMOTE" >/dev/null 2>&1; then
        HAVE_REMOTE=1
    fi
    if (( ! HAVE_REMOTE )); then
        if (( ! SCOPE_LOCAL )); then
            die "remote '$REMOTE' does not exist"
        fi
        echo "Note: remote '$REMOTE' not found; checking local branches only." >&2
        SCOPE_REMOTE=0
    fi

    if (( DO_FETCH && HAVE_REMOTE )); then
        echo "Fetching latest data from '$REMOTE'..."
        git fetch --prune --quiet "$REMOTE" \
            || die "fetch from '$REMOTE' failed; refusing to work from stale data"
    fi

    CUTOFF=$(date -d "$MAX_BRANCH_AGE months ago" +%s) \
        || die "could not compute the cutoff date (GNU date is required)"

    resolve_base
    protect_checked_out_branches

    if (( SCOPE_LOCAL )); then
        scan_refs local refs/heads "refs/heads/"
    fi
    if (( SCOPE_REMOTE )); then
        scan_refs remote "refs/remotes/$REMOTE" "refs/remotes/$REMOTE/"
    fi

    if (( ${#CANDIDATES[@]} == 0 )); then
        echo "No stale or merged branches found (base: $BASE_LABEL, threshold: $MAX_BRANCH_AGE months)."
        exit 0
    fi

    print_report

    if (( ! APPLY )); then
        echo "Dry run: nothing was deleted. Re-run with --delete to remove the branches above."
        exit 0
    fi

    if (( ! ASSUME_YES )) && ! confirm; then
        echo "Aborted. Nothing was deleted."
        exit 0
    fi

    delete_candidates
}

main "$@"