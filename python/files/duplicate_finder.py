#!/usr/bin/env python3
"""Hashes file arrays in a target directory tree and isolates matching identical files."""

import os
from pathlib import Path
import sys
import argparse

dir_path = "\\python\\data\\"
output = None

def main():
    parser = argparse.ArgumentParser(
        description="Hashes file arrays in a target directory tree and isolates " \
        "matching identical files.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  TODO"""
    )
    # The - makes the argument optional
    parser.add_argument("-dir_path", type=Path, help="path of the directory")
    parser.add_argument(
        "-o", "--output", type=Path, help="output file"
    )
    args = parser.parse_args()

    if args.output:
        if not args.output.is_file():
            print(f"error: file not found: {args.output}", file=sys.stderr)
            return 1

    file_list = os.walk('dir_path')
    if (file_list == []):
        print(f"error: no files found inside of: {dir_path}", file=sys.stderr)
        return 1

    hash_table = {}

    for file in file_list:
        hash_table[os.path.getsize(file)] += 1

    duplicate_candidates = [f for f in file_list if hash_table.get([os.path.getsize(duplicate_candidate)]) > 1]
    duplicate_retention = []

    for duplicate_candidate in duplicate_candidates:
        duplicate_retention.append(duplicate_candidate,"with size of",os.path.getsize(duplicate_candidate))

    for x in duplicate_candidates:
        print(x)
    
if __name__ == "__main__":
    sys.exit(main())
