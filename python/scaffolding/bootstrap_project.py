#!/usr/bin/env python3
"""Seed a project folder with a standard layout, README, .gitignore, LICENSE and a starter test."""

import argparse
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

DIRECTORIES = ["docs", "tests", "scripts", "config", ".github/workflows", "src"]
# Folders that already receive a real file, so they don't need a .gitkeep.
NO_GITKEEP = {"tests"}

README_TEMPLATE = """\
# __NAME__

Simple overview of the purpose of this project.

## Build

```
commands to build or run from source
```

## Install

* Prerequisites (libraries, OS version, etc.)
* How to download or install the program

## Environment variables

* `VARIABLE_NAME`: what it does and its default value

## Branches and tags

* Branch naming (for example `feature/<name>`, `bugfix/<name>`)
* Versioning rules (for example `0.1` initial release)

## Tips and tricks

Advice for common problems.
"""

CHANGELOG_TEMPLATE = """\
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

### Changed

### Fixed
"""

CONTRIBUTING_TEMPLATE = """\
# Contributing to __NAME__

Thanks for helping out. Please follow these steps:

1. Fork the repository and create a branch (`feature/<name>` or `bugfix/<name>`).
2. Make your change and add or update tests in `tests/`.
3. Run the linters and tests locally before committing.
4. Open a pull request that explains what changed and why.
5. Add a line to `CHANGELOG.md` under **Unreleased**.
"""

GITIGNORE_TEMPLATE = """\
# Secrets
.env
.env.*
.env.*.local
!.env.example

# Dependencies
node_modules/
venv/
.venv/
__pycache__/
*.py[cod]

# Build output
dist/
build/
out/
target/
*.class
*.jar

# Logs and temp
*.log
logs/
*.tmp
*.temp
*.cache
*.bak

# OS files
.DS_Store
Thumbs.db
*~

# IDE files
.idea/
.vscode/*
!.vscode/extensions.json
*.iml
*.swp

# Tests and coverage
coverage/
.nyc_output/
.pytest_cache/
.coverage
htmlcov/

# Infrastructure
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
.aws/credentials
"""

LICENSE_TEMPLATE = """\
MIT License

Copyright (c) __YEAR__ __AUTHOR__

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

TEST_TEMPLATE = '''\
"""Starter test. Replace with real tests for your project."""


def test_smoke():
    assert True
'''


def render(template, name, author):
    """Fill the placeholders in a template."""
    return (
        template.replace("__NAME__", name)
        .replace("__AUTHOR__", author)
        .replace("__YEAR__", str(date.today().year))
    )


def build_plan(name, author):
    """Return {relative path: content} for every file to create."""
    files = {
        "README.md": render(README_TEMPLATE, name, author),
        "CHANGELOG.md": CHANGELOG_TEMPLATE,
        "CONTRIBUTING.md": render(CONTRIBUTING_TEMPLATE, name, author),
        ".gitignore": GITIGNORE_TEMPLATE,
        "LICENSE": render(LICENSE_TEMPLATE, name, author),
        "tests/test_smoke.py": TEST_TEMPLATE,
    }
    for directory in DIRECTORIES:
        # dir shadows a builtin, and git doesn’t track empty folders
        # so a .gitkeep is needed in each
        if directory not in NO_GITKEEP:
            # "md".join("README") gives "RmdEmdAmdDmdMmdE".
            files[f"{directory}/.gitkeep"] = ""
    return files


def write_files(folder, files, dry_run):
    """Create each file, never overwriting one that already exists."""
    # With .items(), it'd iterate over the dict’s keys only (file names)
    for rel_path, content in files.items():
        target = folder / rel_path
        if dry_run:
            print(f"would create {rel_path}")
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        try:  # "x" instead of "w" because "w" would overwrite an existing file
            with open(target, "x", encoding="utf-8") as f:
                f.write(content)
        except FileExistsError:
            print(f"skipped {rel_path} (already exists)")
        else:
            print(f"created {rel_path}")


def init_git(folder, dry_run):
    """Run `git init` in the folder. Returns True on success."""
    if dry_run:
        print("would run git init")
        return True
    if shutil.which("git") is None:
        print("error: git is not installed or not on PATH", file=sys.stderr)
        return False
    try:  # Instead of adding a git dependency
        subprocess.run(
            ["git", "init", str(folder)], check=True, capture_output=True, text=True
        )
    except subprocess.CalledProcessError as err:
        print(f"error: git init failed: {err.stderr.strip()}", file=sys.stderr)
        return False
    print("initialized git repository")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Create a project skeleton: standard folders, README, CHANGELOG, "
        "CONTRIBUTING, .gitignore, MIT LICENSE, a starter test, and a git repo. "
        "Existing files are never overwritten.",
        epilog="""examples:
  python3 python/scaffolding/bootstrap_project.py ~/projects/my-app
  python3 python/scaffolding/bootstrap_project.py ~/projects/my-app --author "Jane Doe" --dry-run""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "directory",
        type=Path,
        help="folder to create the project in (created if missing)",
    )
    parser.add_argument("--name", help="project name (default: the folder name)")
    parser.add_argument(
        "--author", default="<copyright holder>", help="name for the LICENSE"
    )
    parser.add_argument("--no-git", action="store_true", help="skip git init")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show what would be created, change nothing",
    )
    args = parser.parse_args()

    folder = args.directory.expanduser().resolve()
    if folder.exists() and not folder.is_dir():
        print(f"error: not a folder: {folder}", file=sys.stderr)
        return 1

    name = args.name or folder.name
    files = build_plan(name, args.author)

    if not args.dry_run:
        folder.mkdir(parents=True, exist_ok=True)

    write_files(folder, files, args.dry_run)

    if not args.no_git and not init_git(folder, args.dry_run):
        return 1

    print("Dry run complete." if args.dry_run else f"Project ready in {folder}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
