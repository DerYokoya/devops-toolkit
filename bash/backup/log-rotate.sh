#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# Log rotator
#   - compresses *.log files between AGE_YOUNG and AGE_OLD days old
#     (originals are moved into the archive)
#   - deletes *.log files older than AGE_OLD days
# =========================================================================

# --- Config --------------------------------------------------------------
LOG_DIR="./logs"
AGE_YOUNG=7
AGE_OLD=14
DRY_RUN=0

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help] [--dry-run] [AGE_YOUNG AGE_OLD]

Compresses log files between AGE_YOUNG and AGE_OLD days old into a
timestamped zip archive, then deletes log files older than AGE_OLD days.
Only *.log files directly inside $LOG_DIR are touched.

Arguments:
  AGE_YOUNG    Compress logs at least this many days old (default: 7)
  AGE_OLD      Delete logs older than this many days (default: 14)
               Give both values or neither. AGE_YOUNG must be less than AGE_OLD.

Options:
  --dry-run    Show what would be done without changing anything.
  -h, --help   Show this help message and exit.

Exit status:
  0    Finished (or nothing to do).
  1    A check failed (bad ages, missing log directory, zip not installed).
  2    Invalid command-line usage.

Example (run from the repository root):
  ./bash/log-rotate.sh --dry-run
  ./bash/log-rotate.sh 3 30
EOF
}

# Run a command, or only print it when --dry-run is set.
run() {
    if (( DRY_RUN )); then
        printf 'DRY: '
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# =========================================================================
# Arguments
# =========================================================================
positional_args=()
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        -*)        echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *)         positional_args+=("$arg") ;;
    esac
done

if (( ${#positional_args[@]} == 2 )); then
    AGE_YOUNG="${positional_args[0]}"
    AGE_OLD="${positional_args[1]}"
elif (( ${#positional_args[@]} != 0 )); then
    echo "Give both AGE_YOUNG and AGE_OLD, or neither." >&2
    usage >&2
    exit 2 # exit with status 2 for invalid command-line usage
fi

# =========================================================================
# Validation
# =========================================================================
for name in AGE_YOUNG AGE_OLD; do
    if [[ ! "${!name}" =~ ^[0-9]+$ ]]; then
        echo "refusing: $name must be a non-negative integer (got ${!name})" >&2
        exit 2 # exit with status 2 for invalid command-line usage
    fi
done

# Force base 10 so values like 08 are not read as octal
AGE_YOUNG=$((10#$AGE_YOUNG))
AGE_OLD=$((10#$AGE_OLD))

if (( AGE_YOUNG >= AGE_OLD )); then
    echo "refusing: AGE_YOUNG must be less than AGE_OLD (got $AGE_YOUNG and $AGE_OLD)" >&2
    exit 1 # exit with status 1 for invalid ages
fi

if [[ ! -d "$LOG_DIR" ]]; then
    echo "log directory not found: $LOG_DIR" >&2
    exit 1 # exit with status 1 for missing directory
fi

# =========================================================================
# 1. Compress logs between AGE_YOUNG and AGE_OLD days old
# =========================================================================
out="$LOG_DIR/logs-$(date +%F_%H%M%S).zip"

compression_files=()
mapfile -d '' -t compression_files < <(find "$LOG_DIR" \
    -maxdepth 1 \
    -type f \
    -name "*.log" \
    -newermt "${AGE_OLD} days ago 00:00" \
    ! -newermt "${AGE_YOUNG} days ago 00:00" \
    -print0)

if (( ${#compression_files[@]} )); then
    if ! command -v zip > /dev/null 2>&1; then
        echo "zip not found" >&2
        exit 1 # exit with status 1 for missing binaries
    fi
    # -j stores bare file names, -m moves the originals into the archive
    run zip -j -m "$out" "${compression_files[@]}"
    if (( DRY_RUN )); then
        echo "Would compress ${#compression_files[@]} file(s) (${AGE_YOUNG}-${AGE_OLD} days old) to $out"
    else
        echo "Compressed ${#compression_files[@]} file(s) (${AGE_YOUNG}-${AGE_OLD} days old) to $out"
    fi
else
    echo "nothing to compress" >&2
fi

# =========================================================================
# 2. Delete logs older than AGE_OLD days
# =========================================================================
deletion_files=()
mapfile -d '' -t deletion_files < <(find "$LOG_DIR" \
    -maxdepth 1 \
    -type f \
    -name "*.log" \
    ! -newermt "${AGE_OLD} days ago 00:00" \
    -print0)

if (( ${#deletion_files[@]} )); then
    for file in "${deletion_files[@]}"; do
        run rm -f -- "$file"
    done
    if (( DRY_RUN )); then
        echo "Would delete ${#deletion_files[@]} log file(s) older than ${AGE_OLD} days"
    else
        echo "Deleted ${#deletion_files[@]} log file(s) older than ${AGE_OLD} days"
    fi
else
    echo "nothing to delete" >&2
fi