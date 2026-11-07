#!/usr/bin/env bash
# -E to ensure ERR trap is inherited by functions, command substitutions, and subshells
set -Eeuo pipefail
trap 'echo "$(date +%F_%T) ERROR: line $LINENO: command failed" >&2' ERR

# =========================================================================
# Failed login detector
#   - reads an SSH authentication log
#   - counts "Failed password" lines per source IP address
#   - prints the top offenders, most attempts first
#
# Read-only: the log is never modified. No sudo inside the script; if the
# log needs root to read, run the whole script with sudo.
# =========================================================================

# --- Config --------------------------------------------------------------
LOG_FILE=""   # empty = auto-detect /var/log/auth.log, then /var/log/secure
TOP_N=10

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help] [LOGFILE [TOP_N]]

Scans an SSH authentication log for failed password attempts and lists the
IP addresses with the most failures.

Arguments:
  LOGFILE    Log to scan (default: /var/log/auth.log, or /var/log/secure
             if that does not exist)
  TOP_N      How many addresses to list, at least 1 (default: $TOP_N)

Options:
  -h, --help   Show this help message and exit.

Exit status:
  0    Finished (including when no failed attempts were found).
  1    No readable log file found.
  2    Invalid command-line usage.

Example (run from the repository root):
  ./bash/monitoring/failed-login-detector.sh tests/fixtures/auth-sample.log
  ./bash/monitoring/failed-login-detector.sh tests/fixtures/auth-sample.log 3
  sudo ./bash/monitoring/failed-login-detector.sh      # scan the real system log
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
    1) LOG_FILE="${positional_args[0]}" ;;
    2) LOG_FILE="${positional_args[0]}"
       TOP_N="${positional_args[1]}" ;;
    *) echo "Give at most a LOGFILE and a TOP_N." >&2
       usage >&2
       exit 2 ;;
esac

# =========================================================================
# Validation
# =========================================================================
if [[ ! "$TOP_N" =~ ^[0-9]+$ ]] || (( 10#$TOP_N < 1 )); then
    echo "refusing: TOP_N must be a positive integer (got $TOP_N)" >&2
    exit 2
fi

TOP_N=$((10#$TOP_N))

# No path given: use whichever standard log exists and is readable
# -z tests if the string is empty. -r tests if the file is readable.
if [[ -z "$LOG_FILE" ]]; then
    for candidate in /var/log/auth.log /var/log/secure; do
        if [[ -r "$candidate" ]]; then
            LOG_FILE="$candidate"
            break
        fi
    done
fi

if [[ -z "$LOG_FILE" ]]; then
    echo "no readable log found (tried /var/log/auth.log and /var/log/secure)." >&2
    echo "Pass a path, or try running with sudo." >&2
    exit 1
fi

if [[ ! -r "$LOG_FILE" ]]; then
    echo "cannot read log file: $LOG_FILE (try sudo?)" >&2
    exit 1
fi

# =========================================================================
# 1. Count failed attempts per IP
# =========================================================================
# grep keeps only the failure lines. "|| true" stops grep's "no match" exit
# status (1) from being treated as an error.
#
# awk finds the word "from" and prints the word after it. Looking for "from"
# instead of a fixed column matters: "Failed password for root from IP" and
# "Failed password for invalid user admin from IP" have the IP in different columns.
#
# sort groups identical IPs together (uniq only counts neighbours), uniq -c
# counts each group, sort -rn puts the biggest counts first, and the last awk
# prints the top TOP_N lines, formatted. (awk is used instead of head so sort
# is never cut off mid-write, which can trigger errors under pipefail.)
results="$(
    { grep "Failed password" "$LOG_FILE" || true; } \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "from") { print $(i + 1); break } }' \
        | sort \
        | uniq -c \
        | sort -rn \
        | awk -v n="$TOP_N" 'NR <= n { printf "%7d  %s\n", $1, $2 }'
)"

# =========================================================================
# 2. Report
# =========================================================================
if [[ -z "$results" ]]; then
    echo "No failed password attempts found in $LOG_FILE"
    exit 0
fi

echo "Failed SSH logins by source IP (top $TOP_N) in $LOG_FILE"
echo "  COUNT  IP"
echo "$results"