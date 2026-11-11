#!/usr/bin/env python3
"""Queries target web domains and warns you ahead of time when any SSL certificates are close to expiring."""

import contextlib
from datetime import datetime
import socket
import ssl
import argparse
from typing import Union
from pathlib import Path
import sys
from health_check import read_urls

def get_https_expiry_date(sock: socket, hostname: str) -> Union[int, datetime]:
    """
    Get the expiry date of the HTTPS certificate for a domain.
    """
    ctx = ssl.create_default_context()

    with contextlib.closing(socket.socket(socket.AF_INET)) as sock:
        conn = ctx.wrap_socket(sock, server_hostname=hostname)

        conn.settimeout(5.0)
        conn.connect((hostname, 443))
        ssl_info = conn.getpeercert()

        # Example date: "Oct 17 12:32:16 2024 GMT"
        expiry_date_str = ssl_info["notAfter"]
        expiry_date = datetime.strptime(expiry_date_str, "%b %d %H:%M:%S %Y %Z")

    if expiry_date > datetime.now():
        return 1, 0

    else:
        return 0, expiry_date-datetime.now()

def main():
    parser = argparse.ArgumentParser(
        description="Check if  SSL certificates of given websites are expired.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  python3 python/monitoring/ssl_expiry_check.py https://example.com https://github.com
  python3 python/monitoring/ssl_expiry_check.py https://example.com https://github.com --hostname "Dory"
  python3 python/monitoring/ssl_expiry_check.py --file urls.txt --hostname "Dory"
  python3 python/monitoring/ssl_expiry_check.py -h""",
    )
    parser.add_argument("urls", nargs="*", help="http(s) URLs to check")
    parser.add_argument(
        "-f", "--file", type=Path, help="text file with one URL per line"
    )
    parser.add_argument(
        "-hn",
        "--hostname",
        type=str,
        default="Dory",
        help="Hostname",
    )
    args = parser.parse_args()

    urls = list(args.urls)
    if args.file:
        if not args.file.is_file():
            print(f"error: file not found: {args.file}", file=sys.stderr)
            return 1
        urls += read_urls(args.file, args.hostname)
    if not urls:
        parser.error("give at least one URL, or use --file")

    not_urls = [u for u in urls if not u.startswith(("http://", "https://"))]
    if not_urls:
        parser.error(f"not an http(s) URL: {', '.join(not_urls)}")

    summary = ""
    for url in urls:
        results = get_https_expiry_date(urls, args.timeout)
        if (results[0] == 1):
            summary.append(url,"will expire in",results[1],'\n')

        else:
            summary.append(url,"is expired!",'\n')
            
    print(summary)

if __name__ == "__main__":
    sys.exit(main())
