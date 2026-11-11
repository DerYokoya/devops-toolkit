import ssl

import pytest

from python.monitoring import ssl_expiry_check as sec
from python.monitoring.ssl_expiry_check import (
    check_url,
    classify,
    days_remaining,
    is_https_url,
    main,
    read_urls,
)

EXPIRY = "Jan 01 00:00:00 2030 GMT"
EXPIRY_SECONDS = ssl.cert_time_to_seconds(EXPIRY)
DAY = 86400


def test_days_remaining_counts_whole_days():
    assert days_remaining(EXPIRY, EXPIRY_SECONDS - 10 * DAY) == 10
    assert (
        days_remaining(EXPIRY, EXPIRY_SECONDS - 10 * DAY - 3600) == 10
    )  # 10 days + 1 hour
    assert days_remaining(EXPIRY, EXPIRY_SECONDS - 3600) == 0  # expires within the day


def test_days_remaining_is_negative_after_expiry():
    assert days_remaining(EXPIRY, EXPIRY_SECONDS + 5 * DAY) == -5


@pytest.mark.parametrize(
    "days_left, expected",
    [(-1, "EXPIRED"), (0, "WARN"), (30, "WARN"), (31, "OK"), (365, "OK")],
)
def test_classify_thresholds(days_left, expected):
    assert classify(days_left, warn_days=30) == expected


def test_check_url_ok(monkeypatch):
    monkeypatch.setattr(sec, "fetch_not_after", lambda host, port, timeout: EXPIRY)
    result = check_url("https://example.com", 5, 30, now=EXPIRY_SECONDS - 90 * DAY)
    assert (result.status, result.days_left) == ("OK", 90)


def test_check_url_warns_inside_the_threshold(monkeypatch):
    monkeypatch.setattr(sec, "fetch_not_after", lambda host, port, timeout: EXPIRY)
    result = check_url("https://example.com", 5, 30, now=EXPIRY_SECONDS - 10 * DAY)
    assert (result.status, result.days_left) == ("WARN", 10)


def test_check_url_passes_host_and_port(monkeypatch):
    seen = {}

    def fake(host, port, timeout):
        seen.update(host=host, port=port, timeout=timeout)
        return EXPIRY

    monkeypatch.setattr(sec, "fetch_not_after", fake)
    check_url("https://example.com:8443/path", 2.5, 30)
    assert seen == {"host": "example.com", "port": 8443, "timeout": 2.5}


def test_expired_certificate_fails_the_handshake_and_is_reported(monkeypatch):
    def fake(host, port, timeout):
        error = ssl.SSLCertVerificationError(
            1, "certificate verify failed: certificate has expired"
        )
        error.verify_code = 10
        error.verify_message = "certificate has expired"
        raise error

    monkeypatch.setattr(sec, "fetch_not_after", fake)
    result = check_url("https://expired.example", 5, 30)
    assert result.status == "EXPIRED"


def test_other_verification_errors_are_errors_not_expired(monkeypatch):
    def fake(host, port, timeout):
        error = ssl.SSLCertVerificationError(1, "self-signed certificate")
        error.verify_code = 18
        error.verify_message = "self-signed certificate"
        raise error

    monkeypatch.setattr(sec, "fetch_not_after", fake)
    result = check_url("https://self-signed.example", 5, 30)
    assert (result.status, result.detail) == ("ERROR", "self-signed certificate")


def test_connection_failure_is_an_error_not_a_crash(monkeypatch):
    def fake(host, port, timeout):
        raise ConnectionRefusedError()

    monkeypatch.setattr(sec, "fetch_not_after", fake)
    result = check_url("https://down.example", 5, 30)
    assert (result.status, result.detail) == ("ERROR", "ConnectionRefusedError")


@pytest.mark.parametrize(
    "url, expected",
    [
        ("https://example.com", True),
        ("https://example.com:8443/x", True),
        ("http://example.com", False),
        ("example.com", False),
        ("https://", False),
        ("https://example.com:abc", False),
    ],
)
def test_is_https_url(url, expected):
    assert is_https_url(url) is expected


def test_read_urls_skips_blanks_and_comments(tmp_path):
    f = tmp_path / "urls.txt"
    f.write_text("# sites\nhttps://a.example\n\n  https://b.example  \n")
    assert read_urls(f) == ["https://a.example", "https://b.example"]


def test_exit_status_1_when_anything_needs_attention(monkeypatch, capsys):
    monkeypatch.setattr(
        sec, "fetch_not_after", lambda host, port, timeout: "Jan 01 00:00:00 2099 GMT"
    )
    monkeypatch.setattr(
        "sys.argv", ["ssl_expiry_check", "https://a.example", "--warn-days", "99999"]
    )
    assert main() == 1
    assert "1 of 1 need attention" in capsys.readouterr().out


def test_exit_status_0_when_all_ok(monkeypatch, capsys):
    monkeypatch.setattr(
        sec, "fetch_not_after", lambda host, port, timeout: "Jan 01 00:00:00 2099 GMT"
    )
    monkeypatch.setattr("sys.argv", ["ssl_expiry_check", "https://a.example"])
    assert main() == 0
    assert "All 1 certificates OK" in capsys.readouterr().out


def test_http_url_is_a_usage_error(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["ssl_expiry_check", "http://a.example"])
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 2
    assert "not an https URL" in capsys.readouterr().err