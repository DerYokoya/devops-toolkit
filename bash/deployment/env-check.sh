#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# Environment checker
#   - required binaries present on PATH
#   - each tool's version >= a per-tool minimum
#   - mandatory .env variables exist and are non-empty
# =========================================================================

# --- Config --------------------------------------------------------------
declare -a checks=( node python3 npm git docker pip tsc yarn )

# Per-tool minimum versions (associative array: key = command, value = min)
declare -A minver=(
    [node]="20.0.0"
    [python3]="3.9"
    [npm]="10.0.0"
    [git]="2.40.0"
    [docker]="25.0.0"
    [pip]="23.0.0"
    [tsc]="5.0.0"
    [yarn]="1.22.0"   # bump to 4.0.0 if you use Yarn Berry
)

env_file=".env"
declare -a required_env=( NODE_ENV DATABASE_URL API_KEY )

# --- State ---------------------------------------------------------------
declare -a found=()
missing=0       # missing binaries
outdated=0      # present but outdated
missing_env=0   # missing or empty env vars

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<'EOF'
Usage: env-check.sh [-h|--help]

Checks that the required development and deployment tools are installed,
meet their minimum versions, and that required variables are set in ./.env.

Tools checked:
  node       >= 20.0.0
  python3    >= 3.9
  npm        >= 10.0.0
  git        >= 2.40.0
  docker     >= 25.0.0
  pip        >= 23.0.0
  tsc        >= 5.0.0
  yarn       >= 1.22.0

Required .env variables:
  NODE_ENV
  DATABASE_URL
  API_KEY

Note:
    The script checks .env relative to the directory from which it is
    launched, not relative to the script's own directory.

Options:
  -h, --help    Show this help message and exit.

Exit status:
  0    All checks passed.
  1    One or more tools are missing/outdated, or .env variables are missing.
  2    Invalid command-line usage.

Example (run from the repository root):
  chmod +x bash/deployment/env-check.sh    # once, to make it executable
  ./bash/deployment/env-check.sh --help
  ./bash/deployment/env-check.sh
EOF
}

# Extract a bare dotted version from a tool's --version output.
# Formats differ per tool, so extraction is per-tool; comparison is shared.
get_version() {
    # sed and awk are used to extract the version number from the output of
    # the --version command for each tool. The case statement handles each tool
    # separately, as their version output formats can vary significantly.
    # if none of the specific cases match, it falls back to a generic extraction method.
    case "$1" in
        node)    node    --version 2>/dev/null | sed 's/^v//' ;;
        python3) python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' ;;
        npm)     npm     --version 2>/dev/null ;;
        git)     git     --version 2>/dev/null | awk '{print $3}' ;;
        docker)  docker  --version 2>/dev/null | sed -E 's/.*version ([0-9.]+).*/\1/' ;;
        pip)     pip     --version 2>/dev/null | awk '{print $2}' ;;
        tsc)     tsc     --version 2>/dev/null | awk '{print $2}' ;;
        yarn)    yarn    --version 2>/dev/null ;;
        *)       "$1"    --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 ;;
    esac
}

# version_ge HAVE NEED -> 0 if HAVE >= NEED, 1 otherwise.
# sort -V is version sort: 3.9 sorts before 3.14 (plain sort would not).
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# =========================================================================
# Arguments
# =========================================================================
case "${1:-}" in # ${1:-} means "if $1 is unset or empty, use an empty string"
    # if the argument is -h or --help, call the usage function and
    # exit with status 0 (success).
    -h|--help) usage; exit 0 ;; 
    "")        ;; # if the argument is an empty string, do nothing in this branch.
    # if the argument is anything else, print an error message to stderr,
    # call the usage function, and exit with status 2 (incorrect usage).
    *)         echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

# =========================================================================
# 1. Binaries present?
# =========================================================================
for cmd in "${checks[@]}"; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        echo "$cmd not found" >&2
        missing=$((missing + 1))
        continue
    fi
    found+=("$cmd")
done

# =========================================================================
# 2. Version checks (loop over everything found)
# =========================================================================
for cmd in "${found[@]}"; do
    need="${minver[$cmd]:-}"
    [[ -z "$need" ]] && continue

    have="$(get_version "$cmd")"

    if [[ -z "$have" ]]; then
        printf '%-8s could not determine version (need >= %s)\n' "$cmd" "$need" >&2
        outdated=$((outdated + 1))
    elif version_ge "$have" "$need"; then
        printf '%-8s %s (ok, need >= %s)\n' "$cmd" "$have" "$need"
    else
        printf '%-8s %s (need >= %s)\n' "$cmd" "$have" "$need" >&2
        outdated=$((outdated + 1))
    fi
done

# =========================================================================
# 3. Mandatory .env variables
# =========================================================================
if [[ ! -f "$env_file" ]]; then
    echo "$env_file not found" >&2
    missing_env=${#required_env[@]}
else
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a

    for key in "${required_env[@]}"; do
        if [[ -z "${!key:-}" ]]; then
            echo "env var $key is missing or empty" >&2
            missing_env=$((missing_env + 1))
        fi
    done
fi

# =========================================================================
# Summary
# =========================================================================
(( missing     > 0 )) && echo "$missing tool(s) missing"        >&2
(( outdated    > 0 )) && echo "$outdated tool(s) outdated"      >&2
(( missing_env > 0 )) && echo "$missing_env env var(s) missing" >&2

if (( missing > 0 || outdated > 0 || missing_env > 0 )); then
    exit 1
fi

echo "All checks passed."