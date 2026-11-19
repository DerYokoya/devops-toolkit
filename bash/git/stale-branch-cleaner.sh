#!/usr/bin/env bash
# -E to ensure ERR trap is inherited by functions, command substitutions, and subshells
set -Eeuo pipefail
trap 'echo "$(date +%F_%T) ERROR: line $LINENO: command failed" >&2' ERR

# =========================================================================
# Pre-commit check
#   - shell files (*.sh):  bash -n (syntax) and shellcheck
#   - python files (*.py): ruff check, ruff format --check, pytest
#   - by default only STAGED files are considered; --all checks every
#     tracked and untracked (non-ignored) file in the repository
#   - runs every check, reports all failures, then exits 1 if any failed
#
# Read-only: nothing is modified. Mirrors what CI runs, so a commit that
# passes here should pass on GitHub too.
# =========================================================================

# --- Config --------------------------------------------------------------
MAX_BRANCH_AGE=12
EXCLUDED_BRANCHES='(development|master|production)$'
DRY_RUN=0
# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help] [--all]

Runs the linters and tests on the files you are about to commit and blocks
the commit if any check fails.

Checks:
  *.sh    bash -n (syntax), shellcheck
  *.py    ruff check, ruff format --check, pytest
          (the Python checks run only if at least one .py file is selected)

Options:
  --all        Check every tracked and untracked (non-ignored) file instead of
               only the staged ones.
  -h, --help   Show this help message and exit.

Exit status:
  0    All checks passed (or there was nothing to check).
  1    A check failed, a required tool is missing, or this is not a git repository.
  2    Invalid command-line usage.

Example (run from anywhere inside the repository):
  ./bash/git/pre-commit-check.sh          # staged files only
  ./bash/git/pre-commit-check.sh --all    # whole codebase

Install as a Git hook, so it runs before every commit:
  printf '#!/usr/bin/env bash\nexec "\$(git rev-parse --show-toplevel)/bash/git/pre-commit-check.sh"\n' \\
      > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
Skip it once, in an emergency, with: git commit --no-verify
EOF
}

# =========================================================================
# Arguments
# =========================================================================
positional_args=()
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;; # Help message
        --all)     ALL=1 ;;         # Check the whole codebase
        -dr|--dry-run) DRY_RUN=0 ;;
        -a|--apply) DRY_RUN=1 ;;
        # Anything else, flag or not, is not accepted
        -*) echo "error" ;;
        *)   positional_args+=("$arg") ;;
    esac
done

if (( ${#positional_args[@]} == 1 )); then
    MAX_BRANCH_AGE=${positional_args[0]}
elif (( ${#positional_args[@]} != 0 )); then
    echo "MAX_BRANCH_AGE, or no argument." >&2
    usage >&2
    exit 2
fi

# =========================================================================
# Setup
# =========================================================================
old_branches=$(
    git branch --all \
        | sed 's/^\*/ /' \
        | sed 's/^\s*//' \
        | sed 's/^remotes\///' \
        | grep --invert-match --extended-regexp "$EXCLUDED_BRANCHES" \
        | while read name; do
            if [[ 0 = $(git log "Branch $name" --since "$MAX_BRANCH_AGE months ago" | wc -l) ]]
            then
               echo "$name"
            fi
          done \
)

while IFS= read -r name
do
    if [[ "$name" == origin/* ]]
    then
        name_no_origin_prefix=${name#origin/}
        if (( ! DRY_RUN )); then
            git push origin --delete "$name_no_origin_prefix"
        else
            echo "Would have committed and pushed the changes of $name_no_origin_prefix and then deleted it"
        fi
    else
        if (( ! DRY_RUN )); then
            git branch --delete "$name"
        else
            echo "Would have deleted $name"
        fi
    fi
done <<< "$old_branches"

echo "Ready to commit! Pre-commit check passed."