#!/usr/bin/env python3
"""Check HTTPS certificates and warn when any are close to expiring or already expired."""

import argparse
import socket
import ssl
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

MAX_WORKERS = 10
X509_CERT_HAS_EXPIRED = 10  # OpenSSL's verify code for "certificate has expired"


@dataclass
class Result:
    url: str
    status: str  # OK, WARN, EXPIRED or ERROR
    days_left: int | None = None
    detail: str | None = None


def days_remaining(not_after, now):
    """Whole days from `now` (epoch seconds) until a notAfter string like 'Oct 17 12:32:16 2024 GMT'.

    Negative means the certificate has already expired. cert_time_to_seconds is used instead
    of strptime because it ignores the system locale and always works in UTC.
    """
    expiry = ssl.cert_time_to_seconds(not_after)
    # Gets the number of whole days remaining, rounding down. 86400 seconds per day.
    # Can be negative if the certificate has already expired.
    return int((expiry - now) // 86400)


def classify(days_left, warn_days):
    if days_left < 0:
        return "EXPIRED"
    if days_left <= warn_days:
        return "WARN"
    return "OK"


def fetch_not_after(host, port, timeout):
    """Connect over TLS and return the certificate's notAfter string. This is the only network code."""
    # Creates a context with sensible security defaults
    # Including certificate verification
    context = ssl.create_default_context()

    # Creates socket and wraps it in TLS, then reads the certificate's notAfter field.
    # The with statement ensures the socket is closed when done.

    # getpeercert() returns a dict with the certificate's fields, including 'notAfter'.

    # TLS is a form of encryption that protects the connection from eavesdropping
    # and tampering.
    with (
        socket.create_connection((host, port), timeout=timeout) as sock,
        context.wrap_socket(sock, server_hostname=host) as tls,
    ):
        return tls.getpeercert()["notAfter"]


def check_url(url, timeout, warn_days, now=None):
    """Check one https URL. Never raises: every failure becomes a Result."""
    # time.time() returns a float representing seconds,
    # while datetime.now() returns a human-readable object
    # example of time.time() output: 1794359888.6400099
    # example of datetime.now() output: 2026-11-11 01:18:08.640053

    now = time.time() if now is None else now
    parsed = urlparse(url)
    try:  # if the port is not specified, default to 443 for HTTPS
        not_after = fetch_not_after(parsed.hostname, parsed.port or 443, timeout)
    except ssl.SSLCertVerificationError as exc:
        # With the default settings an expired certificate fails the handshake itself,
        # so its date can't be read.
        if exc.verify_code == X509_CERT_HAS_EXPIRED:
            return Result(url, "EXPIRED", detail="certificate has expired")
        return Result(url, "ERROR", detail=exc.verify_message)
    except OSError as exc:
        # refused, timed out, DNS failure, other TLS errors (SSLError is an OSError too)
        return Result(url, "ERROR", detail=type(exc).__name__)

    days = days_remaining(not_after, now)
    return Result(url, classify(days, warn_days), days)


def check_all(urls, timeout, warn_days):
    """Check every URL in parallel. Results come back in the same order as urls."""
    workers = min(len(urls), MAX_WORKERS)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(lambda url: check_url(url, timeout, warn_days), urls))


def read_urls(path):
    """One URL per line; blank lines and lines starting with # are ignored."""
    lines = (line.strip() for line in path.read_text().splitlines())
    return [line for line in lines if line and not line.startswith("#")]


def is_https_url(url):
    try:
        parsed = urlparse(url)
        _ = parsed.port  # raises ValueError for a bad port such as :abc
    except ValueError:
        return False
    return parsed.scheme == "https" and bool(parsed.hostname)


def print_report(results):
    width = max(len(r.url) for r in results)
    print(f"{'URL':<{width}}  {'DAYS':>5}  {'STATUS':<7}  DETAIL")
    for r in results:
        days = str(r.days_left) if r.days_left is not None else "-"
        print(f"{r.url:<{width}}  {days:>5}  {r.status:<7}  {r.detail or ''}".rstrip())

    needs_attention = sum(r.status != "OK" for r in results)
    print()
    if needs_attention:
        print(f"{needs_attention} of {len(results)} need attention")
    else:
        print(f"All {len(results)} certificates OK")


def main():
    parser = argparse.ArgumentParser(
        description="Check the SSL certificate of each https URL and report how many days "
        "remain. Exits with status 1 if any certificate is expired, expires within "
        "--warn-days, or could not be checked.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  python3 python/monitoring/ssl_expiry_check.py https://example.com https://github.com
  python3 python/monitoring/ssl_expiry_check.py --file urls.txt --warn-days 14
  python3 python/monitoring/ssl_expiry_check.py -h""",
    )
    parser.add_argument("urls", nargs="*", help="https URLs to check")
    parser.add_argument(
        "-f", "--file", type=Path, help="text file with one URL per line"
    )
    parser.add_argument(
        "-w",
        "--warn-days",
        type=int,
        default=30,
        help="warn when this many days or fewer remain (default: 30)",
    )
    parser.add_argument(
        "-t",
        "--timeout",
        type=float,
        default=5.0,
        help="seconds to wait per host (default: 5)",
    )
    args = parser.parse_args()

    if args.timeout <= 0:
        parser.error("--timeout must be greater than 0")
    if args.warn_days < 0:
        parser.error("--warn-days must be 0 or more")

    urls = list(args.urls)
    if args.file:
        if not args.file.is_file():
            print(f"error: file not found: {args.file}", file=sys.stderr)
            return 1
        urls += read_urls(args.file)
    if not urls:
        parser.error("give at least one URL, or use --file")

    not_https = [u for u in urls if not is_https_url(u)]
    if not_https:
        parser.error(f"not an https URL: {', '.join(not_https)}")

    results = check_all(urls, args.timeout, args.warn_days)
    print_report(results)
    return 1 if any(r.status != "OK" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
