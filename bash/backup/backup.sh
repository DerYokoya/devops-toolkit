#!/usr/bin/env bash
# -E to ensure ERR trap is inherited by functions, command substitutions, and subshells
set -Eeuo pipefail
trap 'echo "$(date +%F_%T) ERROR: line $LINENO: command failed" >&2' ERR

# =========================================================================
# Backup
#   - archives the TARGET folder into a timestamped .tar.gz inside BACKUP
#   - keeps only the newest N archives and deletes the older ones
#   - TARGET is only read, never modified or deleted
#   - DRY RUN BY DEFAULT: nothing changes unless --apply is given
#
# Portable on Linux, macOS, and Windows (Git Bash / WSL): uses only tar,
# gzip, and Bash 3.2-compatible syntax.
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
Usage: $(basename "$0") [-h|--help] [--apply] [TARGET BACKUP [N]]

Archives the TARGET folder into a timestamped .tar.gz inside the BACKUP
folder, then deletes the oldest archives so only the newest N remain.
TARGET is never modified. Only files named backup-*.tar.gz inside BACKUP
are ever deleted.

By default this is a DRY RUN: it prints what it would do and changes nothing.
Pass --apply to actually create the archive and delete old ones.

Arguments:
  TARGET    The folder to back up (default: $TARGET)
  BACKUP    Where the archives are saved (default: $BACKUP)
  N         How many backups to keep, at least 1 (default: $N)
            Give TARGET and BACKUP together, or no arguments at all.

Options:
  --apply      Make real changes instead of a dry run.
  -h, --help   Show this help message and exit.

Exit status:
  0    Finished.
  1    A check failed (missing TARGET, BACKUP inside TARGET, tar/gzip not installed).
  2    Invalid command-line usage.

Example (run from the repository root):
  ./bash/backup.sh                                  # dry run with defaults
  ./bash/backup.sh --apply                          # back up and keep the newest $N
  ./bash/backup.sh --apply ~/project ~/backups 10   # custom folders, keep 10

Scheduling with cron (use the full path; cron does not load your shell config):
  0 3 * * * /full/path/to/backup.sh --apply ~/project ~/backups 7 >> ~/backup.log 2>&1

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
        --apply)   DRY_RUN=0 ;;     # Really runs the script
        # Any string that starts with - but isn't -h, --help, or --apply
        -*)        echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *)         positional_args+=("$arg") ;;
    esac
done

# ${#positional_args[@]} is the NUMBER of arguments (the # matters!)
case ${#positional_args[@]} in
    0) ;;
    2) TARGET="${positional_args[0]}"
       BACKUP="${positional_args[1]}" ;;
    3) TARGET="${positional_args[0]}"
       BACKUP="${positional_args[1]}"
       N="${positional_args[2]}" ;;
    *) echo "Give TARGET and BACKUP (optionally followed by N), or no arguments." >&2
       usage >&2
       exit 2 ;;
esac

# =========================================================================
# Validation
# =========================================================================
if [[ ! "$N" =~ ^[0-9]+$ ]] || (( 10#$N < 1 )); then
    echo "refusing: N must be a positive integer (got $N)" >&2
    exit 2
fi
N=$((10#$N))   # base 10, so 08 is not read as octal

if [[ ! -d "$TARGET" ]]; then
    echo "target directory not found: $TARGET" >&2
    exit 1
fi

for tool in tar gzip; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "$tool not found" >&2
        exit 1
    fi
done

if (( DRY_RUN )); then
    echo "DRY RUN (default): no files will be changed. Use --apply to execute."
fi

# =========================================================================
# 1. Create the archive
# =========================================================================
# An archive stored inside the folder it backs up would grow with every run.
# BACKUP may not exist yet, so walk up to the nearest folder that does.
probe="$BACKUP"
while [[ ! -d "$probe" ]]; do
    probe="$(dirname "$probe")"
done
target_abs="$(cd "$TARGET" && pwd -P)"
probe_abs="$(cd "$probe" && pwd -P)"
case "$probe_abs/" in
    "$target_abs"/*)
        echo "refusing: BACKUP ($BACKUP) is inside TARGET ($TARGET)" >&2
        exit 1 ;;
esac

run mkdir -p "$BACKUP"

out="$BACKUP/backup-$(date +%F_%H%M%S).tar.gz"

# -C makes tar read from TARGET; "." archives everything inside it,
# including subfolders, with paths kept relative.
run tar -czf "$out" -C "$TARGET" .

# Make sure the archive can be read back before trusting it
if (( ! DRY_RUN )); then
    tar -tzf "$out" > /dev/null
    echo "Backed up $TARGET to $out"
else
    echo "Would back up $TARGET to $out"
fi

# =========================================================================
# 2. Keep only the newest N archives
# =========================================================================
# Archive names contain a sortable timestamp, so the glob lists them oldest
# first. Only backup-*.tar.gz files are considered, nothing else in BACKUP.
# shopt -s nullglob so that if there are no matches, the array is empty instead
# of containing the literal string.
# shopt -u nullglob restores the default behavior afterward.
shopt -s nullglob
archives=("$BACKUP"/backup-*.tar.gz)
shopt -u nullglob

total=${#archives[@]}
# In a dry run the new archive doesn't exist yet, so count it
if (( DRY_RUN )); then
    total=$((total + 1))
fi

excess=$((total - N))
if (( excess > 0 )); then
    for f in "${archives[@]:0:excess}"; do
        run rm -f -- "$f"
    done
    if (( DRY_RUN )); then
        echo "Would delete $excess old backup(s), keeping the newest $N"
    else
        echo "Deleted $excess old backup(s), keeping the newest $N"
    fi
else
    echo "nothing to delete (keeping up to $N backups)"
fi

if (( DRY_RUN )); then
    echo "Dry run complete. Re-run with --apply to make these changes."
fi