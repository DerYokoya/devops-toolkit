#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# Disk Memory Monitor
#   - TODO
#
# TODO
# =========================================================================

# --- Config --------------------------------------------------------------
STORAGE_LIMIT=750000
RAM_LIMIT=75%

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help] [STORAGE LIMIT] [RAM LIMIT]

Checks resource usage on a schedule and alerts you when it passes a set threshold.
Parse output from df and free. Set customizable warning/critical thresholds.
Implement alert system (e.g., stdout, log)

Arguments:
  STORAGE_LIMIT    (default: 750GB)
  RAM_LIMIT        (default: 75%)
                   Give STORAGE_LIMIT and RAM_LIMIT together, or no arguments at all.

Options:
  -h, --help   Show this help message and exit.

Exit status:
  0    Finished.
  1    A check failed
  2    Invalid command-line usage.

Example (run from the repository root):
  TODO

EOF
}

validation() {
    # Validate STORAGE_LIMIT is a number
    if ! [[ "$STORAGE_LIMIT" =~ ^[0-9]+$ ]]; then
        echo "Error: STORAGE_LIMIT must be a number (in GB)." >&2
        exit 2
    fi

    # Validate RAM_LIMIT is a percentage (e.g., 75%)
    if ! [[ "$RAM_LIMIT" =~ ^[0-9]+%$ ]]; then
        echo "Error: RAM_LIMIT must be a percentage (e.g., 75%)." >&2
        exit 2
    fi

    if [[ "${RAM_LIMIT%?}" -lt 0 || "${RAM_LIMIT%?}" -gt 100 ]]; then
        echo "Error: RAM_LIMIT must be between 0% and 100%." >&2
        exit 2
    fi
}

# =========================================================================
# Arguments
# =========================================================================
positional_args=()
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;; # Help message
        # Any string that starts with - but isn't -h, --help, or --apply
        -*)        echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *)         positional_args+=("$arg") ;;
    esac
done

# ${#positional_args[@]} is the NUMBER of arguments (the # matters!)
case ${#positional_args[@]} in
    0) ;;
    2) STORAGE_LIMIT="${positional_args[0]}"
       RAM_LIMIT="${positional_args[1]}" ;;
    *) echo "Give STORAGE_LIMIT and RAM_LIMIT (optionally followed by N), or no arguments." >&2
       usage >&2
       exit 2 ;;
esac

# =========================================================================
# 1. ...
# =========================================================================

validation()

# Get current RAM usage. free -h gives human-readable output.
# | pipes the output to awk, which prints the 2nd column of Mem (the total memory).
CURRENT_STORAGE=$(free -h | awk '/Mem:/ {print $2}')
echo "Current storage usage: $CURRENT_STORAGE"

# Get current disk usage. df -h gives human-readable output.
# | pipes the output to awk, which prints the 5th column (the percentage used).
CURRENT_RAM=$(df -h | awk '{print $5}')
echo "Current RAM usage: $CURRENT_RAM"

if [[ "$CURRENT_STORAGE" -gt "$STORAGE_LIMIT" ]]; then
    echo "Warning: Storage usage is above the limit of $STORAGE_LIMIT. \
    Current usage: $CURRENT_STORAGE" tee -a memory_log.txt >&2
    exit 1 ;;
fi

if [[ "$CURRENT_RAM" -gt "$RAM_LIMIT" ]]; then
    echo "Warning: RAM usage is above the limit of $RAM_LIMIT. \
    Current usage: $CURRENT_RAM" tee -a memory_log.txt >&2
    exit 1 ;;
fi