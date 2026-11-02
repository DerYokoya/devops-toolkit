#!/usr/bin/env bash
# -E to ensure ERR trap is inherited by functions, command substitutions, and subshells
set -Eeuo pipefail
trap 'echo "$(date +%F_%T) ERROR: line $LINENO: command failed" >&2' ERR

# =========================================================================
# Disk and memory monitor
#   - reads disk usage (df) for STORAGE_PATH and RAM usage (free)
#   - compares each against a percentage limit
#   - on a breach: prints an alert to stderr, appends it to a log file,
#     and exits with status 1
#
# Linux and WSL only: macOS and Git Bash have no `free` command.
# =========================================================================

# --- Config --------------------------------------------------------------
STORAGE_LIMIT=80                              # percent of the disk in use
RAM_LIMIT=75                                  # percent of RAM in use
STORAGE_PATH="/"                              # which filesystem to check
LOG_FILE="${MONITOR_LOG:-$HOME/monitor.log}"  # alerts are appended here

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help] [STORAGE_LIMIT RAM_LIMIT]

Checks disk and RAM usage and alerts you when either passes its limit.
Limits are percentages from 1 to 100; a trailing % is allowed (75 or 75%).

Arguments:
  STORAGE_LIMIT    Alert when the disk holding $STORAGE_PATH is more than this
                   percent full (default: $STORAGE_LIMIT)
  RAM_LIMIT        Alert when more than this percent of RAM is in use,
                   not counting cache that can be freed (default: $RAM_LIMIT)
                   Give STORAGE_LIMIT and RAM_LIMIT together, or no arguments at all.

Options:
  -h, --help   Show this help message and exit.

Alerts are printed to stderr and appended, with a timestamp, to:
  $LOG_FILE
Set the MONITOR_LOG environment variable to use a different file.

Exit status:
  0    Both disk and RAM are within their limits.
  1    A limit was exceeded, or a required tool (df, free) is missing.
  2    Invalid command-line usage.

Example (run from the repository root):
  ./bash/disk-mem-monitor.sh               # use the default limits
  ./bash/disk-mem-monitor.sh 90 80         # alert above 90% disk or 80% RAM

Scheduling with cron every 5 minutes (use the full path; the script writes
alerts to its own log file, so the output can be discarded):
  */5 * * * * /full/path/to/disk-mem-monitor.sh 90 80 > /dev/null 2>&1
EOF
}

validation() {
    local name # Restricts name to this function's scope, so it doesn't leak into the global scope.
    for name in STORAGE_LIMIT RAM_LIMIT; do
        # ${!name} is the value of the variable whose NAME is stored in $name
        if [[ ! "${!name}" =~ ^[0-9]+$ ]] || (( 10#${!name} < 1 || 10#${!name} > 100 )); then
            echo "refusing: $name must be a whole number from 1 to 100 (got ${!name})" >&2
            exit 2
        fi
    done
}

# Print an alert to stderr and append it to the log file.
# tee -a appends; >&2 sends tee's own output to stderr instead of stdout.
alert() {
    # +%F_%T gives a timestamp like 2026-06-05_14:30:00.
    # $1 is the first argument to the function, which is the alert message.
    echo "$(date +%F_%T) ALERT: $1" | tee -a "$LOG_FILE" >&2
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
    2) STORAGE_LIMIT="${positional_args[0]}"
       RAM_LIMIT="${positional_args[1]}" ;;
    *) echo "Give STORAGE_LIMIT and RAM_LIMIT together, or no arguments." >&2
       usage >&2
       exit 2 ;;
esac

# =========================================================================
# Validation
# =========================================================================
# Allow "75%" as well as "75": ${var%\%} removes one trailing %
STORAGE_LIMIT="${STORAGE_LIMIT%\%}"
RAM_LIMIT="${RAM_LIMIT%\%}"

validation

# Base 10, so a value like 08 is not read as octal
STORAGE_LIMIT=$((10#$STORAGE_LIMIT))
RAM_LIMIT=$((10#$RAM_LIMIT))

for tool in df free; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "$tool not found (this script needs Linux or WSL)" >&2
        exit 1
    fi
done

# =========================================================================
# 1. Measure
# =========================================================================
# df -P gives one stable POSIX line per filesystem. NR==2 skips the header,
# $5 is the "Use%" column, and gsub removes the % sign so we can compare numbers.
storage_used="$(df -P "$STORAGE_PATH" | awk 'NR==2 { gsub("%", "", $5); print $5 }')"

# free (no -h) prints plain numbers. Column 2 is total, column 7 is "available"
# (memory that can be used without swapping). Used share = (total - available) / total.
ram_used="$(free | awk '/^Mem:/ { printf "%d", ($2 - $7) / $2 * 100 }')"

echo "Disk ($STORAGE_PATH): ${storage_used}% used (limit ${STORAGE_LIMIT}%)"
echo "RAM: ${ram_used}% used (limit ${RAM_LIMIT}%)"

# =========================================================================
# 2. Compare (check both before exiting, so one alert never hides the other)
# =========================================================================
breached=0

if (( storage_used > STORAGE_LIMIT )); then
    alert "disk $STORAGE_PATH is ${storage_used}% full (limit ${STORAGE_LIMIT}%)"
    breached=1
fi

if (( ram_used > RAM_LIMIT )); then
    alert "RAM is ${ram_used}% in use (limit ${RAM_LIMIT}%)"
    breached=1
fi

if (( breached )); then
    exit 1
fi

echo "OK: usage is within both limits."