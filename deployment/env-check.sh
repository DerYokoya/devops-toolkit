#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# Environment checker
#   - required binaries present on PATH
#   - Python >= minimum version
#   - mandatory .env variables exist and are non-empty
# =========================================================================

# --- Config --------------------------------------------------------------
declare -a checks=( node python3 npm git docker pip tsc yarn ) # <-- edit to change required binaries
minPy="3.9"
minNode="20.0.0"
minNpm="10.0.0"
minGit="2.40.0"
minDocker="25.0.0"
minPip="23.0.0"
minTsc="5.0.0"
minYarn="1.22.0" # maybe change to 4.0.0 if you use yarn berry

env_file=".env"
declare -a required_env=( NODE_ENV DATABASE_URL API_KEY )   # <-- edit to change required env vars

# --- State ---------------------------------------------------------------
declare -a found=()
missing=0 # missing binaries
outdated=0 # present but outdated binaries
missing_env=0 # missing or empty env vars

# =========================================================================
# 1. Binaries
# =========================================================================
# @ is for array expansion, to iterate over the array elements
for cmd in "${checks[@]}"; do
    # /dev/null to discard stdout
    # &1 to stdout
    # 2>&1 to redirect stderr to stdout
    if ! command -v "$cmd" > /dev/null 2>&1; then
        echo "$cmd not found" >&2 # &2 to stderr
        missing=$((missing + 1))
        continue # we don't want to try to get the version of a missing binary
    fi
    found+=("$cmd")
    # /dev/null to discard stderr
    # &2 to stderr
    # head -n1 to get only the first line of output (some commands print multiple lines)
    ver="$("$cmd" --version 2>/dev/null | head -n1)"
    # %-8s to left-align the command name in a field of width 8
    printf '%-8s %s\n' "$cmd" "${ver:-?}"
done

# =========================================================================
# 2. Python minimum version
# =========================================================================
pyVer="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

if ! python3 -c "
import sys
req = tuple(int(p) for p in '${minPy}'.split('.'))
cur = sys.version_info[:2]
sys.exit(0 if cur >= req else 1)
"; then
    echo "Python version $pyVer is less than required version $minPy" >&2
    outdated=$((outdated + 1))
else
    echo "Python version $pyVer is up to date (>= $minPy)"
fi

# =========================================================================
# 3. Mandatory .env variables
# =========================================================================
# -f checks if the file exists and is a regular file
if [[ ! -f "$env_file" ]]; then
    echo "$env_file not found" >&2
    missing_env=${#required_env[@]}
else
    # Load KEY=VALUE pairs without re-executing values. `set -a` marks every
    # assignment in the sourced file as exported, so the vars survive past
    # the `source` line.
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a # turn off export for subsequent assignments

    for key in "${required_env[@]}"; do
    # -z checks if the variable is unset or empty.
    # ${!key}: the variable named python instead of the text python
    # :- is added as a default value if the referenced variable is unset or empty
    # for example, ${!key:-123} will return 123 if the variable is unset or empty, instead of throwing an error.
        if [[ -z "${!key:-}" ]]; then
            echo "env var $key is missing or empty" >&2
            missing_env=$((missing_env + 1))
        fi
    done
fi

# =========================================================================
# Summary
# =========================================================================
# If the condition is true, the command after && is executed. If false, it is skipped.
(( missing     > 0 )) && echo "$missing tool(s) missing"       >&2
(( outdated    > 0 )) && echo "$outdated tool(s) outdated"     >&2
(( missing_env > 0 )) && echo "$missing_env env var(s) missing" >&2

if (( missing > 0 || outdated > 0 || missing_env > 0 )); then
    exit 1
fi

echo "All checks passed."
