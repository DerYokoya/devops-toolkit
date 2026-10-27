#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
positional_args=()
for arg in "$@"; do
    if [[ $arg == "--dry-run" ]]; then
        DRY_RUN=1
    else
        positional_args+=("$arg")
    fi
done

run() {
    if (( DRY_RUN )); then
        printf 'DRY: '
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Files AGE_YOUNG..AGE_OLD days old get compressed; older than AGE_OLD get deleted
AGE_YOUNG=${positional_args[0]:-7}

AGE_OLD=${positional_args[1]:-14}

if (( AGE_YOUNG >= AGE_OLD )); then
    echo "refusing: AGE_YOUNG must be less than AGE_OLD (got $AGE_YOUNG and $AGE_OLD)" >&2
    exit 1
fi

out="backup-$(date +%F_%H%M%S).zip"

# COMPRESSION step
# -maxdepth 1 ignores subdirectories
compression_files=()
mapfile -d '' -t compression_files < <(find . \
    -maxdepth 1 \
    -type f \
    -name "*.log" \
    ! -name "backup-*.zip" \
    -newermt "${AGE_OLD} days ago 00:00" \
    ! -newermt "${AGE_YOUNG} days ago 00:00" \
    -print0)

if ((${#compression_files[@]})); then
    run zip "$out" "${compression_files[@]}"
    if (( DRY_RUN )); then
        echo "Would compress files ${AGE_YOUNG}-${AGE_OLD} days old to $out"
    else
        echo "Compressed files ${AGE_YOUNG}-${AGE_OLD} days old to $out"
    fi
else
    echo "nothing to compress" >&2
fi

# DELETION step
if (( AGE_OLD < 1 )); then
    echo "refusing: AGE_OLD must be >= 1 (got $AGE_OLD)" >&2
    exit 1
fi

deletion_files=()
mapfile -d '' -t deletion_files < <(find ./logs \
    -type f \
    -name "*.log" \
    ! -newermt "${AGE_OLD} days ago 00:00" \
    -print0)

for file in "${deletion_files[@]}"; do
    run rm -f -- "$file"
done

if (( DRY_RUN )); then
    echo "Would delete log files older than ${AGE_OLD} days"
else
    echo "Deleted log files older than ${AGE_OLD} days"
fi