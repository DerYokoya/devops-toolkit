#!/usr/bin/env python3
"""Pings a list of URLs or ports and reports which infrastructure pieces are unresponsive."""

import requests as rq
import argparse
import sys
import asyncio
import aiofiles
import aiohttp

async def get_website(website_arg, timeout):
    async with aiohttp.ClientSession() as session:
        async with session.get(website_arg, timeout=timeout) as resp:
            r = await resp.json()
            if (r.status_code) > 299:
                print("Error: ",r.status_code)
    return r

def main():
    timeout = 1
    ip_list = ['https://api.github.com/events', 'https://google.ca']

    parser = argparse.ArgumentParser(
        description="Pings a list of URLs or ports and reports which infrastructure pieces are unresponsive.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=r"""examples:
  python .\python\monitoring\health_check.py --timeout 1 --ip_list ['https://api.github.com/events', 'https://google.ca']
  python .\python\monitoring\health_check.py -h""",
    )
    parser.add_argument(
        "-tm",
        "--timeout",
        type=float,
        help="Timeout in seconds",
    )
    parser.add_argument(
        "-ip"
        "--ip_list",
        type=bytearray,
        help="List of URLs/IPs/Ports",
    )

    args = parser.parse_args()

    if not isinstance(args.timeout, (int, float)):
        print(f"error: timeout must be a number: {args.timeout}", file=sys.stderr)
        return 1

    if not isinstance(args.ip_list, (str, bytearray)):
        print(f"error: ip_list must be an array or a string: {args.ip_list}", file=sys.stderr)
        return 1

    timeout = args.timeout
    ip_list = args.ip_list
    for x in ip_list:
        get_website(x, timeout)

if __name__ == "__main__":
    sys.exit(main())

