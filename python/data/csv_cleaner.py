#!/usr/bin/env python3
"""Clean a messy CSV: drop duplicate rows, standardize dates, isolate rows with missing values."""

import argparse
import sys
from pathlib import Path

import pandas as pd

DATE_FORMATS = {
    "YYYY-MM-DD": "%Y-%m-%d",
    "YYYY/MM/DD": "%Y/%m/%d",
    "Month D, YYYY": "%B %d, %Y",
    "MM/DD/YYYY": "%m/%d/%Y",
}


def clean(df, date_column=None, date_format="YYYY-MM-DD"):
    """Return (good_rows, duplicate_rows, bad_rows). Row labels are kept from the input."""
    # duplicated() returns one True/False per row: True for every repeat after the first
    duplicate_mask = df.duplicated()
    duplicates = df[duplicate_mask]
    # ~duplicate_mask is the opposite: True for every row that is not a duplicate
    df = df[~duplicate_mask].copy()

    if date_column:
        # Unparseable dates become NaT (the date version of NaN), so they get caught below
        parsed = pd.to_datetime(df[date_column], errors="coerce", format="mixed")
        formatted = parsed.dt.strftime(DATE_FORMATS[date_format])
        if date_format == "Month D, YYYY":
            formatted = formatted.str.replace(r" 0(?=\d,)", " ", regex=True)
        df[date_column] = formatted

    # isna() is True where a cell is empty; any(axis=1) collapses each row to one True/False
    missing_mask = df.isna().any(axis=1)
    return df[~missing_mask], duplicates, df[missing_mask]


def csv_lines(frame):
    """Row labels -> line numbers as seen in a text editor (+1 for the header, +1 for 1-based)."""
    return ", ".join(str(i + 2) for i in frame.index) or "none"


def main():
    parser = argparse.ArgumentParser(
        description="Remove duplicate rows, standardize dates, and set aside rows with "
        "missing values. The input file is never modified.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=r"""examples:
  python .\python\data\csv_cleaner.py .\python\data\data.csv
  python .\python\data\csv_cleaner.py .\python\data\data.csv -o .\cleaned.csv
  python .\python\data\csv_cleaner.py .\python\data\data.csv --output .\cleaned.csv
  python .\python\data\csv_cleaner.py .\python\data\data.csv --date-column date
  python .\python\data\csv_cleaner.py .\python\data\data.csv --date-column date -o .\cleaned.csv
  python .\python\data\csv_cleaner.py .\python\data\data.csv --date-column date --date-format "MM/DD/YYYY"
  python .\python\data\csv_cleaner.py -h""",
    )
    parser.add_argument("input", type=Path, help="CSV file to clean")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="where to write the cleaned rows (default: <input>.cleaned.csv)",
    )
    parser.add_argument(
        "--date-column",
        help="name of a column to convert; unparseable dates count as missing",
    )
    parser.add_argument(
        "--date-format",
        choices=DATE_FORMATS,
        default="YYYY-MM-DD",
        help="output date format (default: YYYY-MM-DD)",
    )
    args = parser.parse_args()

    if not args.input.is_file():
        print(f"error: file not found: {args.input}", file=sys.stderr)
        return 1

    output = args.output or args.input.with_suffix(".cleaned.csv")
    rejected = args.input.with_suffix(".rejected.csv")
    if output.resolve() == args.input.resolve():
        print("error: output must be a different file from the input", file=sys.stderr)
        return 1

    try:
        df = pd.read_csv(args.input)
    except pd.errors.EmptyDataError:
        print(f"error: {args.input} is empty", file=sys.stderr)
        return 1

    if args.date_column and args.date_column not in df.columns:
        print(f"error: no column named {args.date_column!r}", file=sys.stderr)
        return 1

    good, duplicates, bad = clean(df, args.date_column, args.date_format)

    good.to_csv(output, index=False)
    if not bad.empty:
        bad.to_csv(rejected, index=False)

    print("=== SUMMARY ===")
    print(f"Rows read: {len(df)}")
    print(f"Duplicates (CSV lines): {csv_lines(duplicates)}")
    print(f"Missing/invalid values (CSV lines): {csv_lines(bad)}")
    print(f"Clean rows written to: {output} ({len(good)} rows)")
    if not bad.empty:
        print(f"Rejected rows written to: {rejected} ({len(bad)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
