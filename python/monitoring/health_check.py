#!/usr/bin/env python3
"""Check a list of URLs and report which ones are unresponsive."""

import argparse
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

import requests

MAX_WORKERS = 10

# Dataclass is used to force type checking of the Result attributes,
# and to make it easy to add new attributes in the future.
# Error is optional.
@dataclass
class Result:
    url: str
    up: bool
    status: int | None
    seconds: float
    error: str | None = None


def check_url(url, timeout):
    """Check one URL. Never raises: every failure becomes a Result with up=False."""
    # monotic time avoids problems with system clock changes during the request.
    start = time.monotonic()
    try:
        # timeout applies to connecting and to waiting for data, each separately
        response = requests.get(url, timeout=timeout)
    except requests.RequestException as exc:
        # ConnectionError, Timeout, TooManyRedirects, are all caught here
        return Result(url, False, None, time.monotonic() - start, type(exc).__name__)

    seconds = time.monotonic() - start
    if response.status_code >= 400:
        return Result(
            url, False, response.status_code, seconds, f"HTTP {response.status_code}"
        )
    return Result(url, True, response.status_code, seconds)


def check_all(urls, timeout):
    """Check every URL in parallel. Results come back in the same order as urls."""
    # Picks what's smaller between the number of URLs and MAX_WORKERS
    workers = min(len(urls), MAX_WORKERS)
    # ThreadPoolExecutor.map returns results in the same order as the input iterable.
    with ThreadPoolExecutor(max_workers=workers) as pool:
        # This maps a lambda function that calls check_url with the timeout
        # argument to each URL in urls.
        return list(pool.map(lambda url: check_url(url, timeout), urls))


def read_urls(path):
    """One URL per line; blank lines and lines starting with # are ignored."""
    # Gets the text of the file, splits it into lines, and strips whitespace
    # from each line.
    lines = (line.strip() for line in path.read_text().splitlines())
    # Filters out blank lines and lines starting with #,
    # returning a list of valid URLs.
    return [line for line in lines if line and not line.startswith("#")]


def print_report(results):
    # Max width of the URL column as the length of the longest URL in results.
    width = max(len(r.url) for r in results)
    # Header row contains column names, with URL left-aligned, STATUS left-aligned,
    # TIME right-aligned, and RESULT left-aligned.
    print(f"{'URL':<{width}}  {'STATUS':<6}  {'TIME':>7}  RESULT")
    for r in results:
        status = str(r.status) if r.status else "-"
        outcome = "UP" if r.up else f"DOWN ({r.error})"
        print(f"{r.url:<{width}}  {status:<6}  {r.seconds:>6.2f}s  {outcome}")

    down = sum(not r.up for r in results)
    print()
    print(
        f"{down} of {len(results)} unresponsive"
        if down
        else f"All {len(results)} responsive"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Check http(s) URLs in parallel and report which ones are unresponsive. "
        "Exits with status 1 if any URL is down.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  python3 python/monitoring/health_check.py https://example.com https://github.com
  python3 python/monitoring/health_check.py --file urls.txt --timeout 2
  python3 python/monitoring/health_check.py -h""",
    )
    parser.add_argument("urls", nargs="*", help="http(s) URLs to check")
    parser.add_argument(
        "-f", "--file", type=Path, help="text file with one URL per line"
    )
    parser.add_argument(
        "-t",
        "--timeout",
        type=float,
        default=5.0,
        help="seconds to wait per URL (default: 5)",
    )
    args = parser.parse_args()

    if args.timeout <= 0:
        parser.error("--timeout must be greater than 0")

    urls = list(args.urls)
    if args.file:
        if not args.file.is_file():
            print(f"error: file not found: {args.file}", file=sys.stderr)
            return 1
        urls += read_urls(args.file)
    if not urls:
        parser.error("give at least one URL, or use --file")

    not_urls = [u for u in urls if not u.startswith(("http://", "https://"))]
    if not_urls:
        parser.error(f"not an http(s) URL: {', '.join(not_urls)}")

    results = check_all(urls, args.timeout)
    print_report(results)
    return 1 if any(not r.up for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())