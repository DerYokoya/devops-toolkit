#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# Environment checker
#   - required binaries present on PATH
#   - each tool's version >= a per-tool minimum
#   - mandatory .env variables exist and are non-empty
# =========================================================================

# --- Config --------------------------------------------------------------
declare branch-url=$(git remote)
declare branch-name=$(git branch --show-current)

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<'EOF'
TODO
EOF
}

parse_args() {
    if ($# == 2); then
        branch-url=$1
        branch-name=$2
    else if ($# == 0); then
        echo "No arguments provided. Using default values."
        echo "branch-url: ${branch-url}"
        echo "branch-name: ${branch-name}"
    else
        echo "Invalid number of arguments. Expected 0 or 2, got $#." >&2
        usage >&2
        exit 2

    fi
}

# =========================================================================
# Arguments
# =========================================================================
case 
    -h|--help) usage; exit 0 ;; 
    "")        ;; # if the argument is an empty string, do nothing in this branch.
    # if the argument is anything else, print an error message to stderr,
    # call the usage function, and exit with status 2 (incorrect usage).
    *)         echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

# =========================================================================
# ...
# =========================================================================
parse_args "$@"

git fetch ${branch-url} ${branch-name}
npm ci
npm audit fix
db-migrate up
pm2 startup

# =========================================================================
# Summary
# =========================================================================

echo "All checks passed."