#!/usr/bin/env python3
"""Instantly seeds a pristine code repo with a standardized folder framework, custom .gitignore, README, and unit testing boilerplate."""

import argparse
import shutil
import sys
import time
from pathlib import Path
from git import Repo
from datetime import date
import os

def apply_moves(moves):
    """Create the subfolders and move the files. The only function that changes anything."""
    for source, destination in moves:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(source, destination)

def create_repo(folder):
    repo = Repo.init(folder)
    print("Repo created.")
    print(".git folder created")
    create_markdown(folder)
    print("Markdown files created")
    create_empty_folders(folder)
    print("Empty folders created")
    create_gitignore(folder)
    print("Created .gitignore")
    create_license(folder)
    print("LICENSE created")

def create_markdown(folder):
    default_markdown = {"README": "# PROJECT NAME\n"\
                        "============\n"\
                        "\n"\
                        "Simple overview of use/purpose, and how to contribute to this project.\n"\
                        "\n"\
                        "### Build command\n"\
                        "\n"\
                        "* How to build/run the program from source\n"\
                        "* Step-by-step bullets\n"\
                        "```\n"\
                        "code blocks for commands\n"\
                        "```\n"\
                        "\n"\
                        "### Install command\n"\
                        "\n"\
                        "* Prerequisites, libraries, OS version, etc. needed before installing (ex. Windows 10)\n"\
                        "* How/where to download the program\n"\
                        "* Any modifications needed to files/folders\n"\
                        "```\n"\
                        "code blocks for commands\n"\
                        "```\n"\
                        "\n"\
                        "### Environment Variables\n"\
                        "\n"\
                        "* VARIABLE_NAME: description of what it does and its default value\n"\
                        "* ANOTHER_VARIABLE: description\n"\
                        "\n"\
                        "### Private Branches & Tags\n"\
                        "\n"\
                        "* Branch naming conventions (ex. feature/<name>, bugfix/<name>)\n"\
                        "* Tagging and versioning rules (ex. 0.1 - Initial Release, 0.2 - Bug fixes)\n"\
                        "* See [commit change]() or [release history]()\n"\
                        "\n"\
                        "## Tips & Tricks\n"\
                        "\n"\
                        "Advice for common problems or issues.\n"\
                        "```\n"\
                        "command to run if program contains helper info\n"\
                        "```\n"\
                        "\n",
                        "CHANGELOG": "# Change Log\n"\
                        "All notable changes to this project will be documented in this file.\n"\
                        "\n"\
                        "The format is based on [Keep a Changelog](http://keepachangelog.com/)\n"\
                        "and this project adheres to [Semantic Versioning](http://semver.org/).\n"\
                        "\n"\
                        "## [Unreleased] - yyyy-mm-dd\n"\
                        "\n"\
                        "Here we write upgrading notes for brands. It's a team effort to make them as\n"\
                        "straightforward as possible.\n"\
                        "\n"\
                        "### Added\n"\
                        "- [PROJECTNAME-XXXX](http://tickets.projectname.com/browse/PROJECTNAME-XXXX)\n"\
                        "  MINOR Ticket title goes here.\n"\
                        "- [PROJECTNAME-YYYY](http://tickets.projectname.com/browse/PROJECTNAME-YYYY)\n"\
                        "  PATCH Ticket title goes here.\n"\
                        "\n"\
                        "### Changed\n"\
                        "\n"\
                        "### Fixed\n"\
                        "\n"\
                        "## [1.2.4] - 2017-03-15\n"\
                        "\n"\
                        "Here we would have the update steps for 1.2.4 for people to follow.\n"\
                        "\n"\
                        "### Added\n"\
                        "\n"\
                        "### Changed\n"\
                        "\n"\
                        "- [PROJECTNAME-ZZZZ](http://tickets.projectname.com/browse/PROJECTNAME-ZZZZ)\n"\
                        "  PATCH Drupal.org is now used for composer.\n"\
                        "\n"\
                        "### Fixed\n"\
                        "\n"\
                        "- [PROJECTNAME-TTTT](http://tickets.projectname.com/browse/PROJECTNAME-TTTT)\n"\
                        "  PATCH Add logic to runsheet teaser delete to delete corresponding\n"\
                        "  schedule cards.\n"\
                        "\n"\
                        "## [1.2.3] - 2017-03-14\n"\
                        "\n"\
                        "### Added\n"\
                        "\n"\
                        "### Changed\n"\
                        "\n"\
                        "### Fixed\n"\
                        "\n", 
                        "CONTRIBUTING": "# CONTRIBUTING\n"\
                        "============\n"\
                        "\n"\
                        "### Build command\n"\
                        "### Install command"\
                        "### Environment Variables"\
                        "### Private Branches & Tags"\
                        "## Tips & Tricks"}

    for md_file, content in default_markdown:        
        with open(folder/md_file.join("md"), 'w') as f:
            f.write(content)

def create_empty_folders(folder):
    directories = ["docs", "tests", "scripts", "config", ".github/workflows", "src/main", "src/test"]

    for dir in directories:
        os.mkdir(folder/dir)

def create_gitignore(folder):
    GITIGNORE_TEMPLATE = "# ----Secrets ----\n"\
                     ".env\n"\
                     ".env.*\n"\
                     ".env.*.local\n"\
                     "!.env.example\n"\
                     "\n"\
                     "# --Dependencies --\n"\
                     "node_modules/\n"\
                     "venv/\n"\
                     ".venv/\n"\
                     "__pycache__/\n"\
                     "*.py[cod]\n"\
                     "\n"\
                     "# --Build Output --\n"\
                     "dist/\n"\
                     "build/\n"\
                     "out/\n"\
                     "target/\n"\
                     "*.class\n"\
                     "*.jar\n"\
                     "\n"\
                     "# -- Logs & Temp ----\n"\
                     "*.log\n"\
                     "logs/\n"\
                     "*.tmp\n"\
                     "*.temp\n"\
                     "*.cache\n"\
                     "*.bak\n"\
                     "\n"\
                     "# -- OS Files---\n"\
                     ".DS_Store\n"\
                     "Thumbs.db\n"\
                     "*~\n"\
                     "\n"\
                     "# --IDE Files -----\n"\
                     ".idea/\n"\
                     ".vscode/\n"\
                     "!.vscode/extensions.json\n"\
                     "*.iml\n"\
                     "*.swp\n"\
                     "\n"\
                     "# ---- Test & Coverage ---\n"\
                     "coverage/\n"\
                     ".nyc_output/\n"\
                     ".pytest_cache/\n"\
                     ".coverage\n"\
                     "htmlcov/\n"\
                     "\n"\
                     "# -- Infrastructure ---\n"\
                     ".terraform/\n"\
                     "*.tfstate\n"\
                     "*.tfstate.*\n"\
                     "*.tfvars\n"\
                     "!*.tfvars.example\n"\
                     ".aws/credentials\n"

    with open(folder/".gitignore") as f:
        f.write(GITIGNORE_TEMPLATE)

def create_license(folder):
    today = date.today()
    this_year = str(today.strftime("%Y"))

    LICENSE_TEMPLATE = "Copyright (c)" + this_year + "<copyright holders>\n"\
                   "\n"\
                   "Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n"\
                   "\n"\
                   "The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n"\
                   "\n"\
                   "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.\n"

    with open(folder/"LICENSE") as f:
        f.write(LICENSE_TEMPLATE)

def main():
    parser = argparse.ArgumentParser(
        description="Build boilerplate templates or string skeletons internally. " \
        "Scaffold folder architectures reliably using pathlib or os." \
        "Output matching project components (README.md, .gitignore, test directories)."
        "(Optional) Initialize a local git repo within the targeted folder scope",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  python3 python/scaffolding/bootstrap_project.py ~/Downloads
  python3 python/scaffolding/bootstrap_project.py -h""",
    )
    parser.add_argument("directory", type=Path, help="folder to create the repo in")
    args = parser.parse_args()

    if not args.directory.is_dir():
        print(f"error: not a folder: {args.directory}", file=sys.stderr)
        return 1
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
