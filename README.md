![Status](https://img.shields.io/badge/status-in%20development-orange)

# devops-toolkit

A collection of small Bash and Python scripts that automate repetitive system, deployment, and monitoring tasks. Bash handles quick command-line glue work, and Python handles anything that needs parsing, APIs, or real error handling.

![Shell Check](https://github.com/DerYokoya/devops-toolkit/actions/workflows/shellcheck.yml/badge.svg?branch=main)
![Python Check](https://github.com/DerYokoya/devops-toolkit/actions/workflows/python.yml/badge.svg?branch=main)

## Why this exists

Manual, repetitive tasks are slow and error-prone. Each script here replaces one of them with something repeatable, logged, and safe to run on a schedule.

## Repository structure

```
devops-toolkit/
├── README.md
├── LICENSE
├── .gitignore
├── requirements.txt
├── .github/
│   └── workflows/
│       ├── shellcheck.yml                # ShellCheck every push
│       └── python.yml                    # Ruff lint/format + pytest on every push
├── bash/
│   ├── backup/
│   │   ├── backup.sh
│   │   ├── log-rotate.sh
│   │   └── pg-backup-restore.sh
│   ├── monitoring/
│   │   ├── disk-memory-monitor.sh
│   │   ├── failed-login-detector.sh
│   │   └── cron-audit.sh
│   ├── deployment/
│   │   ├── deploy.sh
│   │   └── env-check.sh ✅
│   ├── git/
│   │   ├── stale-branch-cleaner.sh
│   │   └── pre-commit-check.sh
│   └── admin/
│       ├── package-update-check.sh
│       └── provision-users.sh
├── python/
│   ├── monitoring/
│   │   ├── health_check.py
│   │   └── ssl_expiry_check.py
│   ├── reporting/
│   │   ├── log_analyzer.py
│   │   └── api_report.py
│   ├── data/
│   │   └── csv_cleaner.py
│   ├── files/
│   │   ├── duplicate_finder.py
│   │   └── organize_files.py
│   └── scaffolding/
│       └── bootstrap_project.py
├── tests/
│   ├── bash/
│   └── python/
└── docs/
    └── examples/                   # Sample output, cron entries, screenshots
```

## Scripts

### Bash

| Script | What it does |
|---|---|
| `backup/backup.sh` | Copies a project folder to a timestamped archive and keeps only the last N backups. |
| `backup/log-rotate.sh` | Compresses and archives logs older than a set number of days and deletes the oldest ones. |
| `backup/pg-backup-restore.sh` | Dumps a PostgreSQL database on a schedule and restores it into a test environment on demand. |
| `monitoring/disk-memory-monitor.sh` | Checks disk and memory usage and alerts when a threshold is passed. |
| `monitoring/failed-login-detector.sh` | Scans auth logs for repeated failed SSH attempts and lists the offending IPs. |
| `monitoring/cron-audit.sh` | Lists scheduled jobs on a machine and flags any that failed or have not run recently. |
| `deployment/deploy.sh` | Pulls the latest code, installs dependencies, runs migrations, and restarts the service. |
| `deployment/env-check.sh` | Verifies required tools, versions, and environment variables before a project runs. |
| `git/stale-branch-cleaner.sh` | Finds and deletes Git branches that are merged or untouched for months. |
| `git/pre-commit-check.sh` | Runs the linter and tests before each commit and blocks it if anything fails. |
| `admin/package-update-check.sh` | Lists outdated system packages and flags ones with known vulnerabilities. |
| `admin/provision-users.sh` | Creates users, sets permissions, and adds SSH keys from a single list. |

### Python

| Script | What it does |
|---|---|
| `monitoring/health_check.py` | Pings a list of URLs or ports and reports which ones are down. |
| `monitoring/ssl_expiry_check.py` | Warns when any domain's SSL certificate is close to expiring. |
| `reporting/log_analyzer.py` | Parses application logs and summarizes error counts, slowest endpoints, and top errors. |
| `reporting/api_report.py` | Pulls data from an API and turns it into a CSV or formatted weekly report. |
| `data/csv_cleaner.py` | Removes duplicates, fixes formats, and flags missing values in a messy CSV. |
| `files/duplicate_finder.py` | Hashes files in a directory and reports duplicates. |
| `files/organize_files.py` | Sorts a messy folder into subfolders by file type or date. |
| `scaffolding/bootstrap_project.py` | Creates a new repo with a standard folder structure, `.gitignore`, README, and test setup. |

## Getting started

```bash
git clone https://github.com/DerYokoya/devops-toolkit.git
cd devops-toolkit

# Python dependencies
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Make the Bash scripts executable
chmod +x bash/**/*.sh
```

## Usage examples

```bash
# Back up a project folder, keeping the last 7 backups
./bash/backup/backup.sh /path/to/project /path/to/backups 7

# Check whether a list of services is up
python3 python/monitoring/health_check.py --urls urls.txt

# Summarize today's application logs
python3 python/reporting/log_analyzer.py /var/log/app.log
```

Every script supports `--help` and prints a usage message when run with no arguments. Check `docs/examples/` for sample output.

## Running on a schedule

Most scripts are designed to run from cron. For example, to run the disk monitor every 15 minutes:

```cron
*/15 * * * * /path/to/devops-toolkit/bash/monitoring/disk-memory-monitor.sh
```

## Requirements

- Linux or macOS (tested on Ubuntu 24.04)
- Bash 4+
- Python 3.10+
- Python packages listed in `requirements.txt`

## Testing

```bash
# Lint Bash scripts
shellcheck bash/**/*.sh

# Run Python tests
pytest tests/python
```

GitHub Actions runs both on every push.

## Design principles

- **Safe by default:** scripts use `set -euo pipefail` in Bash and validate input in Python.
- **Dry-run first:** anything destructive (deleting branches, rotating logs) supports a `--dry-run` flag.
- **Readable output:** clear messages and non-zero exit codes on failure, so the scripts work in cron and CI.
- **No hard-coded secrets:** credentials and tokens come from environment variables.

## License

MIT. See [LICENSE](LICENSE).
