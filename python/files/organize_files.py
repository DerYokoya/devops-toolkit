#!/usr/bin/env python3
"""Sort the files in a folder into subfolders by extension or by modification month."""

import argparse
import shutil
import sys
import time
from pathlib import Path


def destination_folder(path, by):
    """Name of the subfolder a file belongs in."""
    if by == "date":
        # Modification time: creation time isn't available on Linux, and st_ctime
        # means something different there (when the file's metadata last changed).
        return time.strftime("%Y-%m", time.localtime(path.stat().st_mtime))
    return path.suffix.lower().lstrip(".") or "no-extension"


def unique_destination(destination, taken):
    """Return destination, or 'name (1).ext', 'name (2).ext', ... if that name is in use.

    "In use" means a file already exists there, or an earlier file in this same plan
    is already going there (nothing has been moved yet while we are planning).
    """
    candidate = destination
    number = 1
    while candidate.exists() or candidate in taken:
        candidate = destination.with_name(
            f"{destination.stem} ({number}){destination.suffix}"
        )
        number += 1
    return candidate


def plan_moves(directory, by="extension"):
    """Decide where every file goes. Moves nothing. Returns (moves, skipped)."""
    moves, skipped, taken = [], [], set()
    for path in sorted(directory.iterdir()):
        # Only plain, visible files sitting directly in the folder: subfolders, hidden
        # files and symlinks are left alone, so running it twice is harmless.
        if path.name.startswith(".") or path.is_symlink() or not path.is_file():
            continue
        try:
            folder = directory / destination_folder(path, by)
        except OSError as exc:
            skipped.append((path, exc.strerror))
            continue
        if folder.exists() and not folder.is_dir():
            skipped.append((path, f"a file named {folder.name!r} is in the way"))
            continue
        destination = unique_destination(folder / path.name, taken)
        taken.add(destination)
        moves.append((path, destination))
    return moves, skipped


def apply_moves(moves):
    """Create the subfolders and move the files. The only function that changes anything."""
    for source, destination in moves:
        destination.parent.mkdir(exist_ok=True)
        shutil.move(source, destination)


def main():
    parser = argparse.ArgumentParser(
        description="Sort the files directly inside a folder into subfolders, either by "
        "extension (photo.JPG goes to jpg/) or by modification month (2026-11/). "
        "Dry run by default: nothing moves unless you pass --apply. Existing files are "
        "never overwritten; a clashing name gets a ' (1)' suffix. Subfolders, hidden "
        "files and symlinks are ignored.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  python3 python/files/organize_files.py ~/Downloads
  python3 python/files/organize_files.py ~/Downloads --apply
  python3 python/files/organize_files.py ~/Downloads --by date --apply
  python3 python/files/organize_files.py -h""",
    )
    parser.add_argument("directory", type=Path, help="folder to organize")
    parser.add_argument(
        "--by",
        choices=["extension", "date"],
        default="extension",
        help="how to sort the files (default: extension)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="actually move the files (default: dry run)",
    )
    args = parser.parse_args()

    if not args.directory.is_dir():
        print(f"error: not a folder: {args.directory}", file=sys.stderr)
        return 1

    moves, skipped = plan_moves(args.directory, args.by)
    for path, reason in skipped:
        print(f"warning: skipped {path.name}: {reason}", file=sys.stderr)

    if not args.apply:
        print(
            "DRY RUN (default): nothing will be moved. Use --apply to move the files."
        )
    for source, destination in moves:
        print(f"{source.name} -> {destination.relative_to(args.directory)}")

    if not moves:
        print("nothing to move")
    elif args.apply:
        apply_moves(moves)
        print(f"Moved {len(moves)} file(s)")
    else:
        print(f"Would move {len(moves)} file(s). Re-run with --apply to move them.")
    return 0


if __name__ == "__main__":
    sys.exit(main())