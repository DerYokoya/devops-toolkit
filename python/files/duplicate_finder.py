#!/usr/bin/env python3
"""Find files with identical contents inside a folder tree. Report only; nothing is deleted."""

import argparse
import hashlib
import os
import sys
from collections import defaultdict
from pathlib import Path

CHUNK_SIZE = (
    65536  # read files 64 KB at a time so a huge file never has to fit in memory
)


def group_by_size(directory):
    """Map file size -> list of files with that size. Returns (sizes, skipped)."""
    # defaultdict(list) is a dict that creates a new empty list for any
    # key that doesn't exist yet
    sizes = defaultdict(list)
    skipped = []
    # os.walk yields (folder, subfolders, filenames) once for every folder in the tree
    for folder, _subfolders, filenames in os.walk(directory):
        for name in filenames:
            path = Path(folder) / name
            # Symlinks are skipped
            if path.is_symlink():
                continue
            try:
                # size of the file in bytes
                size = path.stat().st_size
            except OSError as exc:
                skipped.append((path, exc.strerror))
                continue
            if size > 0:  # empty files are all "identical", which isn't worth reporting
                sizes[size].append(path)
    return sizes, skipped


def hash_file(path):
    """SHA-256 of a file's contents, read in chunks."""
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_duplicates(directory):
    """Return (groups, skipped). Each group is a sorted list of 2+ files with identical contents."""
    sizes, skipped = group_by_size(directory)
    groups = []
    for paths in sizes.values():
        if len(paths) < 2:
            continue  # a file with a unique size cannot have a duplicate, so don't hash it
        by_hash = defaultdict(list)
        for path in paths:
            try:
                by_hash[hash_file(path)].append(path)
            except OSError as exc:
                skipped.append((path, exc.strerror))
        groups.extend(sorted(g) for g in by_hash.values() if len(g) > 1)
    return sorted(groups), skipped


def print_report(groups):
    if not groups:
        print("No duplicate files found")
        return

    wasted = 0
    for number, group in enumerate(groups, start=1):
        size = group[0].stat().st_size
        wasted += size * (len(group) - 1)
        print(f"Group {number}: {len(group)} identical files, {size} bytes each")
        for path in group:
            print(f"  {path}")

    redundant = sum(len(g) - 1 for g in groups)
    print()
    print(
        f"{redundant} redundant file(s) in {len(groups)} group(s); {wasted} bytes could be reclaimed"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Find files with identical contents in a folder tree. Files are only "
        "hashed when another file has the same size. Empty files and symlinks are ignored. "
        "Nothing is ever deleted.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  python3 python/files/duplicate_finder.py tests/fixtures/duplicates
  python3 python/files/duplicate_finder.py ~/Downloads
  python3 python/files/duplicate_finder.py -h""",
    )
    parser.add_argument(
        "directory", type=Path, help="folder to scan (searched recursively)"
    )
    args = parser.parse_args()

    if not args.directory.is_dir():
        print(f"error: not a folder: {args.directory}", file=sys.stderr)
        return 1

    groups, skipped = find_duplicates(args.directory)
    for path, reason in skipped:
        print(f"warning: skipped {path}: {reason}", file=sys.stderr)
    print_report(groups)
    return 0


if __name__ == "__main__":
    sys.exit(main())
