#!/usr/bin/env bash
# -E to ensure ERR trap is inherited by functions, command substitutions, and subshells
set -Eeuo pipefail
trap 'echo "$(date +%F_%T) ERROR: line $LINENO: command failed" >&2' ERR

# =========================================================================
# Backup
#   - DRY RUN BY DEFAULT: nothing changes unless --apply is given
#
# Portable on Linux, macOS, and Windows (Git Bash / WSL): uses TODO
# =========================================================================

# --- Config --------------------------------------------------------------
TARGET="./backup-target"
BACKUP="./backup"
N=5
DRY_RUN=1   # default: only show what would happen; --apply makes real changes

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help] [--apply] [TARGET] [BACKUP] [N]

Compresses log files from the TARGET folder into a .tar.gz archive placed inside
the BACKUP folder, then deletes backups older than the Nth backup.

* files inside $TARGET are touched and files older than the Nth backup in $BACKUP
are deleted.

By default this is a DRY RUN: it prints what it would do and changes nothing.
Pass --apply to actually compress and delete files.

Arguments:
  TARGET    the project you want to back up.
  BACKUP    where the archives get saved.
  N         how many backups to keep. Optional.

Options:
  --apply      Make real changes instead of a dry run.
  -h, --help   Show this help message and exit.

Exit status:
  0    Finished (or nothing to do).
  1    A check failed (bad ages, missing log directory, tar/gzip not installed).
  2    Invalid command-line usage.

Example (run from the repository root):
  TODO

Scheduling with cron (use the full path; cron does not load your shell config):
  0 3 * * * /full/path/to/log-rotate.sh --apply >> ~/log-rotate.log 2>&1

Errors are printed to stderr with a timestamp and the failing line number.
The cron redirect above is what saves them to a file.
EOF
}

# Run a command, or only print it when in dry-run mode.
run() {
    if (( DRY_RUN )); then
        printf 'DRY: '
        printf '%q ' "$@" # $@ is the list of arguments passed to the function.
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
        -h|--help) usage; exit 0 ;; # Help message
        --apply)   DRY_RUN=0 ;; # Really runs the script
        # Any string that starts with - but isn't -h, --help, or --apply
        -*)        echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *)         positional_args+=("$arg") ;;
    esac
done

if (( ${#positional_args[@]} == 3 )); then
    TARGET="${positional_args[0]}"
    BACKUP="${positional_args[1]}"
    N="${positional_args[2]}"
elif (( ${positional_args[@]} == 2)); then
    TARGET="${positional_args[0]}"
    BACKUP="${positional_args[1]}"
elif (( ${#positional_args[@]} != 0 )); then
    echo "Give both TARGET and BACKUP, or  \
    TARGET, BACKUP, and N, or no parameters." >&2
    usage >&2
    exit 2
fi

# =
# Zip Files
# =

in="$TARGET"
out="$BACKUP/backup-$(date +%F_%H%M%S).tar.gz"

compression_files=()
# IFS mean Internal Field Separator. It's to determine how to do word splitting.
# -r prevents backslashes from being interpreted as escape characters.
# -d uses the null character as the delimiter instead of a newline.
while IFS= read -r -d '' f; do
    compression_files+=("$f")
# name "*" to find all files in the TARGET directory
done < <(find "$TARGET" \
    -type f \
    -name "*" \
    -print0)

# Will be skipped if the length of the compression_files array is 0
# (no files to compress)
# tool checks if tar and gzip are installed
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

    run tar -czf "$out" -C "$BACKUP" "${names[@]}"

    if (( ! DRY_RUN )); then
        tar -tzf "$out" > /dev/null
    fi
    run rm -f -- "${compression_files[@]}"

    if (( DRY_RUN )); then
        echo "Would compress ${#compression_files[@]} file(s) into $out"
    else
        echo "Compressed ${#compression_files[@]} file(s) into $out"
    fi
else
    echo "nothing to compress" >&2
fi

