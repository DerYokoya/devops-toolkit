#!/usr/bin/env bash
set -euo pipefail

# If $1 is empty, COMPRESSION defaults to 7
COMPRESSION=${1:-7}

# If $2 is empty, DELETION defaults to 14
DELETION=${2:-14}

# COMPRESSION step
# -maxdepth 1 ignores subdirectories
# xargs -0 to handle filenames with spaces or special characters
find . \
    -maxdepth 1 \
    -type f \
    -newermt "${DELETION} days ago 00:00" \
    ! -newermt "${COMPRESSION} days ago 00:00" \
    -print0 |
    xargs -0 zip "backup-$(date -d "${COMPRESSION} days ago" +%F).zip"

echo "Compressed files from ${DELETION} days ago to ${COMPRESSION} days \
ago to backup-$(date -d "${COMPRESSION} days ago" +%F).zip"

# DELETION step
find ./logs -type f -name "*.log" -mtime +${DELETION} -exec rm -f {} \;
echo "Deleted log files older than ${DELETION} days"