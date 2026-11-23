"""The child's trail (AP74, 11.10.2026) — see `runner/spur.py`."""

from __future__ import annotations

import http.server
import sqlite3
import threading
import time
import urllib.request

import pytest

from cinelounge.portalworks.runner import call, spur


@pytest.fixture
def server():
    class Stumm(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")

        def log_message(self, *a):
            pass

    httpd = http.server.HTTPServer(("127.0.0.1", 0), Stumm)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_address[1]}/"
    httpd.shutdown()


def test_schritte_werden_notiert_und_zusammengefasst(server, tmp_path):
    s = spur.Spur()
    try:
        s.einschalten()
        urllib.request.urlopen(server, timeout=5).read()
        sqlite3.connect(tmp_path / "x.sqlite").close()
    finally:
        spur.ausschalten()
    text = s.zusammenfassung()
    s.aufraeumen()
    assert text is not None
    assert "dns 127.0.0.1" in text
    assert "connect 127.0.0.1:" in text
    assert "antwort 127.0.0.1" in text
    assert "sqlite x.sqlite" in text
    assert "offen" not in text


def test_offener_schritt_wird_genannt():
    s = spur.Spur()
    s._beginn("sqlite", "tmdb.sqlite")
    text = s.zusammenfassung(jetzt=time.time() + 19.4)
    s.aufraeumen()
    assert text is not None
    assert text.startswith("offen: sqlite tmdb.sqlite seit 19.")
    assert s.zusammenfassung() is None


def test_zeile_traegt_die_spur():
    start = time.monotonic() - 20.0
    text = call.zeile(
        "kiefer", "listing", start, "run.timeout", "offen: sqlite tmdb.sqlite seit 19.4 s"
    )
    assert text.startswith("kiefer.listing run.timeout in 20.")
    assert text.endswith(" — offen: sqlite tmdb.sqlite seit 19.4 s")
    assert call.zeile("ahorn", "menu", time.monotonic()).endswith(" s")
