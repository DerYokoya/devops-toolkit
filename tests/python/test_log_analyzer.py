from pathlib import Path

import pytest

from python.reporting.log_analyzer import (
    filter_by_date,
    main,
    parse_line,
    read_records,
    summarize,
)

SAMPLE = Path(__file__).parent / "fixtures" / "app-sample.log"


def test_parse_line_accepts_a_json_record():
    record = parse_line('{"level": "ERROR", "message": "boom"}')
    assert record == {"level": "ERROR", "message": "boom"}


@pytest.mark.parametrize(
    "line",
    [
        "this line is not json",
        '{"level": "INFO"',  # cut off in the middle
        '{"hello": "world"}',  # valid JSON but no level
        '{"level": 5}',  # level is not text
        '["level", "ERROR"]',  # JSON but not an object
    ],
)
def test_parse_line_rejects_unusable_lines(line):
    assert parse_line(line) is None


def test_read_records_counts_skipped_lines():
    records, skipped = read_records(SAMPLE)
    assert len(records) == 12
    assert skipped == 3


def test_summary_of_the_sample_log():
    records, _ = read_records(SAMPLE)
    summary = summarize(records, top_n=3)
    assert summary.total == 12
    assert summary.errors == 5
    assert summary.error_rate == pytest.approx(5 / 12)
    assert summary.top_errors == [
        ("database timeout", 2),
        ("disk almost full", 1),  # ties are sorted alphabetically
        ("invalid credentials", 1),
    ]
    assert [name for name, _, _ in summary.slowest] == [
        "/api/orders",
        "/api/users",
        "/api/login",
    ]
    name, average, requests = summary.slowest[0]
    assert (name, average, requests) == ("/api/orders", 700.0, 4)


def test_top_n_limits_the_lists():
    records, _ = read_records(SAMPLE)
    summary = summarize(records, top_n=1)
    assert len(summary.top_errors) == 1
    assert len(summary.slowest) == 1


def test_records_without_endpoint_or_duration_do_not_break_endpoint_stats():
    records = [
        {"level": "ERROR", "message": "disk almost full"},
        {
            "level": "INFO",
            "endpoint": "/a",
            "duration_ms": True,
        },  # a bool is not a duration
        {"level": "INFO", "endpoint": "/a", "duration_ms": "fast"},
        {"level": "INFO", "endpoint": "/a", "duration_ms": 10},
    ]
    summary = summarize(records)
    assert summary.slowest == [("/a", 10.0, 1)]


def test_empty_input_has_a_zero_error_rate():
    summary = summarize([])
    assert (summary.total, summary.errors, summary.error_rate) == (0, 0, 0.0)


def test_filter_by_date_keeps_only_that_day():
    records, _ = read_records(SAMPLE)
    day = filter_by_date(records, "2026-11-10")
    assert len(day) == 11
    assert summarize(day).errors == 5


def test_cli_prints_the_summary(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["log_analyzer", str(SAMPLE)])
    assert main() == 0
    out = capsys.readouterr().out
    assert "Records: 12 (3 unreadable line(s) skipped)" in out
    assert "Errors: 5 (41.7%)" in out
    assert "database timeout" in out
    assert "/api/orders" in out


def test_cli_missing_file_is_an_error(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["log_analyzer", str(tmp_path / "nope.log")])
    assert main() == 1
    assert "file not found" in capsys.readouterr().err


@pytest.mark.parametrize("extra", [["--date", "11/10/2026"], ["--top", "0"]])
def test_cli_bad_options_are_usage_errors(extra, monkeypatch):
    monkeypatch.setattr("sys.argv", ["log_analyzer", str(SAMPLE), *extra])
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 2
