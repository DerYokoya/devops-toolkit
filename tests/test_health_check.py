import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from python.monitoring.health_check import check_all, check_url, main, read_urls


@pytest.fixture
def server():
    """A throwaway local web server: /ok answers 200, /broken 500, /slow waits 1 second."""

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/slow":
                time.sleep(1)
            self.send_response(500 if self.path == "/broken" else 200)
            self.end_headers()

        def log_message(self, *args):
            pass  # keep test output quiet

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_port}"
    httpd.shutdown()
    httpd.server_close()


@pytest.fixture
def dead_url():
    """A URL on a port nothing is listening on."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    return f"http://127.0.0.1:{port}"


def test_healthy_url_is_up(server):
    result = check_url(f"{server}/ok", timeout=2)
    assert result.up
    assert result.status == 200
    assert result.error is None


def test_http_error_status_is_down(server):
    result = check_url(f"{server}/broken", timeout=2)
    assert not result.up
    assert result.status == 500
    assert result.error == "HTTP 500"


def test_refused_connection_is_down_not_a_crash(dead_url):
    result = check_url(dead_url, timeout=2)
    assert not result.up
    assert result.status is None
    assert result.error == "ConnectionError"


def test_slow_server_times_out(server):
    result = check_url(f"{server}/slow", timeout=0.2)
    assert not result.up
    assert "Timeout" in result.error


def test_check_all_keeps_input_order(server, dead_url):
    urls = [f"{server}/ok", dead_url, f"{server}/broken"]
    results = check_all(urls, timeout=2)
    assert [r.url for r in results] == urls
    assert [r.up for r in results] == [True, False, False]


def test_read_urls_skips_blanks_and_comments(tmp_path):
    f = tmp_path / "urls.txt"
    f.write_text("# my sites\nhttps://a.example\n\n  https://b.example  \n")
    assert read_urls(f) == ["https://a.example", "https://b.example"]


def test_exit_status_is_1_when_something_is_down(server, dead_url, monkeypatch, capsys):
    monkeypatch.setattr(
        "sys.argv", ["health_check", f"{server}/ok", dead_url, "-t", "2"]
    )
    assert main() == 1
    assert "1 of 2 unresponsive" in capsys.readouterr().out


def test_exit_status_is_0_when_all_up(server, monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["health_check", f"{server}/ok", "-t", "2"])
    assert main() == 0
    assert "All 1 responsive" in capsys.readouterr().out


def test_non_url_is_a_usage_error(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["health_check", "google.ca"])
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 2
    assert "not an http(s) URL" in capsys.readouterr().err