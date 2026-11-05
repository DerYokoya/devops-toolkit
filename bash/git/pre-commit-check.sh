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
ALL=0          # 0 = staged files only, 1 = whole codebase
failed=()      # labels of the checks that failed

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
  ./bash/pre-commit-check.sh          # staged files only
  ./bash/pre-commit-check.sh --all    # whole codebase

Install as a Git hook, so it runs before every commit:
  printf '#!/usr/bin/env bash\nexec "\$(git rev-parse --show-toplevel)/bash/pre-commit-check.sh"\n' \\
      > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
Skip it once, in an emergency, with: git commit --no-verify
EOF
}

# Exit with an install hint if a required tool is missing.
need() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "$1 not found ($2)" >&2
        exit 1
    fi
}

# Print the NUL-separated paths matching a pattern (e.g. '*.sh').
# Staged mode: files added, copied or modified in the index (deletions skipped).
list_files() {
    if (( ALL )); then
        git ls-files -z --cached --others --exclude-standard -- "$1"
    else
        git diff --cached --name-only --diff-filter=ACM -z -- "$1"
    fi
}

# check LABEL COMMAND [ARGS...]: run a command, show its output only if it fails,
# and remember the failure. Using "if" keeps set -e from stopping at the first one.
check() {
    local label="$1" output
    # shift removes positional arguments from the function's argument list,
    # shifting everything one position to the left.
    shift
    if output="$("$@" 2>&1)"; then
        echo "ok    $label"
    else
        echo "FAIL  $label" >&2
        printf '%s\n' "$output" | sed 's/^/        /' >&2
        failed+=("$label")
    fi
}

# =========================================================================
# Arguments
# =========================================================================
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;; # Help message
        --all)     ALL=1 ;;         # Check the whole codebase
        # Anything else, flag or not, is not accepted
        *)         echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

# =========================================================================
# Setup
# =========================================================================
if ! root="$(git rev-parse --show-toplevel 2> /dev/null)"; then
    echo "not inside a git repository" >&2
    exit 1
fi
cd "$root"   # so paths and tools behave the same wherever the script is run from

shell_files=()
while IFS= read -r -d '' f; do
    [[ -f "$f" ]] && shell_files+=("$f")
done < <(list_files '*.sh')
# <(list_files '*.sh') creates a file-like input source
# containing the command's output (similar to aninput stream).

python_files=()
while IFS= read -r -d '' f; do
    [[ -f "$f" ]] && python_files+=("$f")
done < <(list_files '*.py')
# < <(list_files '*.py') creates a file-like input source (same as above).
# A pipeline isn't used because a loop executed on the right side of a
# pipeline generally runs in a subshell in Bash. So modifications to
# shell_files might not survive once the loop finishes.
# This is why process substitution is used instead.
# The while loop runs in the current shell.

if (( ALL )); then
    echo "Checking the whole codebase"
else
    echo "Checking staged files"
fi

# =========================================================================
# 1. Shell files
# =========================================================================
if (( ${#shell_files[@]} )); then
    # need function called with two arguments
    need shellcheck "install with: sudo apt install shellcheck"
    for f in "${shell_files[@]}"; do
    # bash -n checks syntax, shellcheck checks for common mistakes and style issues.
        check "bash -n $f" bash -n "$f"
        check "shellcheck $f" shellcheck "$f"
    done
fi

# =========================================================================
# 2. Python files
# =========================================================================
if (( ${#python_files[@]} )); then
    need ruff "install with: pip install ruff"
    need pytest "install with: pip install pytest"
    # Only the selected files, so an unstaged messy file can't block this commit.
    # --force-exclude keeps any exclude rules in your Ruff config working.
    check "ruff check" ruff check --force-exclude "${python_files[@]}"
    check "ruff format --check" ruff format --check --force-exclude "${python_files[@]}"
    # pytest exits with 5 when it finds no tests at all, which is not a failure
    check "pytest" bash -c 'pytest -q || [ $? -eq 5 ]'
fi

# =========================================================================
# Summary
# =========================================================================
if (( ${#shell_files[@]} == 0 && ${#python_files[@]} == 0 )); then
    echo "nothing to check"
fi

if (( ${#failed[@]} )); then
    echo "Pre-commit check failed (${#failed[@]}):" >&2
    printf '  - %s\n' "${failed[@]}" >&2
    exit 1
fi

echo "Ready to commit! Pre-commit check passed."