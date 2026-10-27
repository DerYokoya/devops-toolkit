#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# Log rotator
#   - compresses *.log files between AGE_YOUNG and AGE_OLD days old into a
#     .tar.gz archive (originals are removed once the archive is verified)
#   - deletes *.log files older than AGE_OLD days
#   - DRY RUN BY DEFAULT: nothing changes unless --apply is given
#
# Portable on Linux, macOS, and Windows (Git Bash / WSL): uses only tar,
# gzip, find -mmin, and Bash 3.2-compatible syntax.
# =========================================================================

# --- Config --------------------------------------------------------------
LOG_DIR="./logs"
AGE_YOUNG=7
AGE_OLD=14
DRY_RUN=1   # default: only show what would happen; --apply makes real changes

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help] [--apply] [AGE_YOUNG AGE_OLD]

Compresses log files between AGE_YOUNG and AGE_OLD days old into a
timestamped .tar.gz archive, then deletes log files older than AGE_OLD days.
Only *.log files directly inside $LOG_DIR are touched.

By default this is a DRY RUN: it prints what it would do and changes nothing.
Pass --apply to actually compress and delete files.

Arguments:
  AGE_YOUNG    Compress logs at least this many days old (default: 7)
  AGE_OLD      Delete logs older than this many days (default: 14)
               Give both values or neither. AGE_YOUNG must be less than AGE_OLD.

Options:
  --apply      Make real changes instead of a dry run.
  -h, --help   Show this help message and exit.

Exit status:
  0    Finished (or nothing to do).
  1    A check failed (bad ages, missing log directory, tar/gzip not installed).
  2    Invalid command-line usage.

Example (run from the repository root):
  ./bash/log-rotate.sh                 # dry run with defaults (7 and 14 days)
  ./bash/log-rotate.sh --apply         # compress 7-14 days old, delete older
  ./bash/log-rotate.sh --apply 3 30    # compress 3-30 days old, delete older
EOF
}

# Run a command, or only print it when in dry-run mode.
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
        --apply)   DRY_RUN=0 ;;
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
    exit 2
fi

# =========================================================================
# Validation
# =========================================================================
for name in AGE_YOUNG AGE_OLD; do
    if [[ ! "${!name}" =~ ^[0-9]+$ ]]; then
        echo "refusing: $name must be a non-negative integer (got ${!name})" >&2
        exit 2
    fi
done

# Force base 10 so values like 08 are not read as octal
AGE_YOUNG=$((10#$AGE_YOUNG))
AGE_OLD=$((10#$AGE_OLD))

if (( AGE_YOUNG >= AGE_OLD )); then
    echo "refusing: AGE_YOUNG must be less than AGE_OLD (got $AGE_YOUNG and $AGE_OLD)" >&2
    exit 1
fi

if [[ ! -d "$LOG_DIR" ]]; then
    echo "log directory not found: $LOG_DIR" >&2
    exit 1
fi

# find -mmin works on GNU and BSD/macOS find; -newermt "N days ago" is GNU-only.
young_min=$((AGE_YOUNG * 1440))
old_min=$((AGE_OLD * 1440))

if (( DRY_RUN )); then
    echo "DRY RUN (default): no files will be changed. Use --apply to execute."
fi

# =========================================================================
# 1. Compress logs between AGE_YOUNG and AGE_OLD days old
# =========================================================================
out="$LOG_DIR/logs-$(date +%F_%H%M%S).tar.gz"

compression_files=()
while IFS= read -r -d '' f; do
    compression_files+=("$f")
done < <(find "$LOG_DIR" \
    -maxdepth 1 \
    -type f \
    -name "*.log" \
    -mmin "+${young_min}" \
    ! -mmin "+${old_min}" \
    -print0)

if (( ${#compression_files[@]} )); then
    for tool in tar gzip; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            echo "$tool not found" >&2
            exit 1
        fi
    done

    # Bare file names (with ./ so a name starting with - is never an option)
    names=()
    for f in "${compression_files[@]}"; do
        names+=("./${f##*/}")
    done

    run tar -czf "$out" -C "$LOG_DIR" "${names[@]}"

    # Only remove the originals if the archive can be read back
    if (( ! DRY_RUN )); then
        tar -tzf "$out" > /dev/null
    fi
    run rm -f -- "${compression_files[@]}"

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
while IFS= read -r -d '' f; do
    deletion_files+=("$f")
done < <(find "$LOG_DIR" \
    -maxdepth 1 \
    -type f \
    -name "*.log" \
    -mmin "+${old_min}" \
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

if (( DRY_RUN )); then
    echo "Dry run complete. Re-run with --apply to make these changes."
fi