#Checklist

#Scan specified source folders

#Parse target sorting rules (file extensions or OS creation metadata)

#Create missing destination subdirectories dynamically

#Safely move or rename files while handling naming collisions gracefully

#!/usr/bin/env python3
"""Sorts a messy folder layout into structured subfolders organized strictly by file type extension or creation date."""

import argparse
import hashlib
import os
import sys
from collections import defaultdict
from pathlib import Path

CHUNK_SIZE = (
    65536  # read files 64 KB at a time so a huge file never has to fit in memory
)


def group_by_critera(directory, critera: int = 0):
    """TODO."""
    # 1: creation time, 2: modification time, 3: file type

    # defaultdict(list) is a dict that creates a new empty list for any
    # key that doesn't exist yet
    filtered_contents = defaultdict(list)
    skipped = []
    # os.walk yields (folder, subfolders, filenames) once for every folder in the tree
    for folder, _subfolders, filenames in os.walk(directory):
        for name in filenames:
            path = Path(folder) / name
            # Symlinks are skipped
            if path.is_symlink():
                continue
            try:
                match critera:
                    case 0:
                        # creation time of the file in bytes
                        filter = path.stat().st_ctime
                    case 1:
                        # modification time of the file in bytes
                        filter = path.stat().st_mtime
                    case 2:
                        # file type of the file in bytes
                        filter = os.path.basename(name).split(".").lower()[-1]
                    case _:
                        print(f"{critera} must be a number [0, 2]")

            except OSError as exc:
                skipped.append((path, exc.strerror))
                continue
            if filter > 0:  # empty files are all "identical", which isn't worth reporting
                filtered_contents[filter].append(path)
    return filtered_contents, skipped

def organize_files(directory, critera: int = 0, dry_run = 1):
    """Organizes files"""
    file_groups, skipped = group_by_critera(directory, critera)
    groups = []
    for paths in file_groups.values():
        by_hash = defaultdict(list)
        for path in paths:
            try:
                by_hash[hash_file(path)].append(path)
            except OSError as exc:
                skipped.append((path, exc.strerror))

        if (dry_run == 0):
            groups.extend(sorted(g) for g in by_hash.values() if len(g) > 1)
            print(f"Moved {path} to {paths}")
        else:
            print(f"DRY RUN: Would move {path} to {paths}")
    return sorted(groups), skipped

def hash_file(path):
    """SHA-256 of a file's contents, read in chunks."""
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()

def print_report(groups):
    if not groups:
        print("No duplicate files found")
        return

    wasted = 0
    for number, group in enumerate(groups):
        size = group[number].stat().st_size
        print(f"Group {number}: {len(group)} files of size {size}")
        for path in group:
            print(f"  {path}")

    print()

def main():
    parser = argparse.ArgumentParser(
        description="TODO.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  python3 python/files/organize_files.py tests/fixtures/duplicates
  python3 python/files/organize_files.py ~/Downloads
  python3 python/files/organize_files.py -h""",
    )
    parser.add_argument(
        "directory", type=Path, help="folder to scan (searched recursively)"
    )
    parser.add_argument(
        "-m", "--mode", type=int | str, help="Type as an int or a string"
    )
    args = parser.parse_args()

    if not args.directory.is_dir():
        print(f"error: not a folder: {args.directory}", file=sys.stderr)
        return 1

    match args.mode:
        case 0, "0", "Creation":
            args.mode = 0

        case 1, "1", "Modification":
            args.mode = 1

        case 2, "2", "Extension":
            args.mode = 2

        case _:
            print(f"Current value {args.mode} is wrong, as it must be a number [0, 2]")   
            return 1
        
    groups, skipped = organize_files(args.directory)
    for path, reason in skipped:
        print(f"warning: skipped {path}: {reason}", file=sys.stderr)
    print_report(groups)
    return 0


if __name__ == "__main__":
    sys.exit(main())
