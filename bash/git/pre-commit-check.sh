#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# Pre-commit check
#   - 
# =========================================================================

# --- Config --------------------------------------------------------------
whole_codebase=false
pass=true

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help] [false (whole codebase) or true (staged changes)]

TODO
EOF
}

# =========================================================================
# Arguments
# =========================================================================
positional_args=()
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;; # Help message
        # Any string that starts with - but isn't -h or --help
        -*)        echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *)         positional_args+=("$arg") ;;
    esac
done

# ${#positional_args[@]} is the NUMBER of arguments (the # matters!)
case ${#positional_args[@]} in
    0) ;;
    1) whole_codebase="${positional_args[0]}" ;;
    *) echo "Give at most one argument (whole codebase or staged changes)." >&2
       usage >&2
       exit 2 ;;
esac

# =========================================================================
# Validation
# =========================================================================
if [[ $whole_codebase != true && $whole_codebase != false ]]; then
    echo "refusing: whole_codebase must be either true or false (got $whole_codebase)" >&2
    exit 2
fi

# =========================================================================
# Main
# =========================================================================

bashfiles=()
failedfiles=()

while IFS= read -r -d '' f; do
    bashfiles+=("$f")
done < <(find "/" \
    -type f \
    -name "*.sh" )

for bashfile in "${bashfiles[@]}"; do
    if [[ $whole_codebase == true ]]; then
        echo "Checking $bashfile"
        shfmt "$bashfile"
        bash -n "$bashfile"
        case "$(shellcheck "$bashfile")" in
            0) echo "Yay! No issues detected in $bashfile" ;;
            1) echo "Shellcheck found issues in $bashfile" >&2
               pass=false 
               failedfiles+=("$bashfile") ;;
            2) echo "Error running shellcheck on $bashfile" >&2
               exit 2 ;;
        esac
    else
        # Check only staged changes
        # grep -q returns 0 if it finds a match,
        # 1 if it doesn't, and 2 if there is an error
        # 0 is true in bash, so it can be used in an if statement
        case "$(git diff --cached --name-only | grep -q "$bashfile")" in
            0) echo "Checking $bashfile"
               shfmt "$bashfile"
               bash -n "$bashfile"
               case "$(shellcheck "$bashfile")" in
                   0) echo "Yay! No issues detected in $bashfile" ;;
                   1) echo "Shellcheck found issues in $bashfile" >&2
                      failedfiles+=("$bashfile")
                      pass=false ;;
                   2) echo "Error running shellcheck on $bashfile" >&2
                      exit 2 ;;
               esac ;;
            1) echo "Skipping $bashfile (not staged)" ;;
            2) echo "Error checking if $bashfile is staged" >&2
               exit 2 ;;
        esac
    fi
done

if [[ $pass == false ]]; then
    echo "Pre-commit check failed" >&2
    exit 1
else
    echo "Ready to commit! Pre-commit check passed."
fi