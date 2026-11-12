#!/usr/bin/env python3
"""Summarize JSON-lines application logs: error rate, top errors, and slowest endpoints."""

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

ERROR_LEVELS = {"ERROR", "CRITICAL"}


@dataclass
class Summary:
    total: int
    errors: int
    error_rate: float  # 0.0 to 1.0
    top_errors: list  # [(message, count), ...] most frequent first
    slowest: list  # [(endpoint, average_ms, requests), ...] slowest first


def parse_line(line):
    """Return the log record as a dict, or None if the line is not a usable record."""
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        return None
    # Valid JSON isn't enough: it must be an object with a text "level"
    if not isinstance(record, dict) or not isinstance(record.get("level"), str):
        return None
    return record


def read_records(path):
    """Read one log file. Returns (records, skipped) where skipped counts unusable lines."""
    records = []
    skipped = 0
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.strip():
                continue  # blank lines aren't counted as skipped
            record = parse_line(line)
            if record is None:
                skipped += 1
            else:
                records.append(record)
    return records, skipped


def filter_by_date(records, date):
    """Keep only records whose "time" starts with date (YYYY-MM-DD)."""
    return [r for r in records if str(r.get("time", "")).startswith(date)]


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def summarize(records, top_n=3):
    errors = [r for r in records if r["level"].upper() in ERROR_LEVELS]
    error_counts = Counter(str(r.get("message", "(no message)")) for r in errors)

    durations = defaultdict(list)
    for r in records:
        endpoint, ms = r.get("endpoint"), r.get("duration_ms")
        if endpoint and is_number(ms):
            durations[str(endpoint)].append(ms)

    # Ties are broken alphabetically so the output is the same on every run
    top_errors = sorted(error_counts.items(), key=lambda kv: (-kv[1], kv[0]))[:top_n]
    averages = [(name, sum(v) / len(v), len(v)) for name, v in durations.items()]
    slowest = sorted(averages, key=lambda item: (-item[1], item[0]))[:top_n]

    # Avoids ZeroDivisionError
    error_rate = len(errors) / len(records) if records else 0.0
    return Summary(len(records), len(errors), error_rate, top_errors, slowest)


def print_summary(summary, skipped, top_n):
    print(f"Records: {summary.total} ({skipped} unreadable line(s) skipped)")
    print(f"Errors: {summary.errors} ({summary.error_rate:.1%})")

    print()
    print(f"Top errors (up to {top_n}):")
    if summary.top_errors:
        for message, count in summary.top_errors:
            print(f"  {count:>4}  {message}")
    else:
        print("  none")

    print()
    print(f"Slowest endpoints by average time (up to {top_n}):")
    if summary.slowest:
        for endpoint, average, requests in summary.slowest:
            print(f"  {endpoint:<20} {average:>8.1f} ms  ({requests} requests)")
    else:
        print("  none")


def date_arg(value):
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        raise argparse.ArgumentTypeError(f"{value!r} is not a date like 2026-11-10")
    return value


def main():
    parser = argparse.ArgumentParser(
        description="Summarize JSON-lines application logs (one JSON object per line with a "
        "'level' and, optionally, 'time', 'endpoint', 'duration_ms' and 'message'). "
        "Reports the error rate, the most common errors and the slowest endpoints. "
        "Lines that are not valid records are skipped and counted.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  python3 python/reporting/log_analyzer.py tests/fixtures/app-sample.log
  python3 python/reporting/log_analyzer.py app.log --date 2026-11-10 --top 5
  python3 python/reporting/log_analyzer.py -h""",
    )
    parser.add_argument("files", nargs="+", type=Path, help="log files to read")
    parser.add_argument(
        "-d", "--date", type=date_arg, help="only count records from this day"
    )
    parser.add_argument(
        "-n", "--top", type=int, default=3, help="rows per list (default: 3)"
    )
    args = parser.parse_args()

    if args.top < 1:
        parser.error("--top must be at least 1")

    records, skipped = [], 0
    for path in args.files:
        if not path.is_file():
            print(f"error: file not found: {path}", file=sys.stderr)
            return 1
        file_records, file_skipped = read_records(path)
        records += file_records
        skipped += file_skipped

    if args.date:
        records = filter_by_date(records, args.date)

    print_summary(summarize(records, args.top), skipped, args.top)
    return 0


if __name__ == "__main__":
    sys.exit(main())
