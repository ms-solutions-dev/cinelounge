"""`stream/probe.py` — what counts as a video, and what the probe asks.

Found on 08.11.2026: a speed-test endpoint answers with 512 KB of random bytes
as `application/octet-stream`, ignores the range, and was handed to the
television as a film. These tests answer at home; no request leaves the
machine.
"""

from __future__ import annotations

import pytest

from cinelounge.stream import probe


class _Roh:
    def __init__(self, inhalt: bytes) -> None:
        self.inhalt = inhalt

    def read(self, n: int, decode_content: bool = False) -> bytes:
        return self.inhalt[:n]


class _Antwort:
    def __init__(self, status: int, typ: str, inhalt: bytes) -> None:
        self.status_code = status
        self.headers = {"content-type": typ}
        self.raw = _Roh(inhalt)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class _Sitzung:
    def __init__(self, antwort: _Antwort) -> None:
        self.antwort = antwort
        self.gefragt: list[dict] = []

    def get(self, address, headers=None, **kw):
        self.gefragt.append(dict(headers or {}))
        return self.antwort


def _pruefen(typ: str, inhalt: bytes, address: str = "https://h.example/v", status: int = 200):
    return probe._probe(_Sitzung(_Antwort(status, typ, inhalt)), address, {})


MP4 = b"\x00\x00\x00\x20ftypisom\x00\x00\x02\x00"
MKV = b"\x1a\x45\xdf\xa3" + b"\x00" * 12


def test_zufallsbytes_als_octet_stream_sind_kein_film():
    """The speed test: the type promises a file, the bytes are noise."""
    rauschen = bytes((i * 151 + 7) % 256 for i in range(2048))
    assert rauschen[:1] != b"\x47"
    assert (
        _pruefen("application/octet-stream", rauschen, "https://h.example/api/speedtest?kb=512")
        is None
    )


@pytest.mark.parametrize("kopf", [MP4, MKV, b"FLV\x01" + b"\x00" * 12, b"RIFF" + b"\x00" * 12])
def test_ein_videobehaelter_als_octet_stream_ist_ein_film(kopf):
    fund = _pruefen("application/octet-stream", kopf, status=206)
    assert fund is not None and fund.kind == "datei"


def test_video_typ_wird_weiter_geglaubt():
    """`video/*` stays as it was: the host names it, no signature is asked for."""
    fund = _pruefen("video/mp4", b"\x00\x01", status=206)
    assert fund is not None and fund.kind == "datei"


def test_transportstrom_braucht_einen_zweiten_beleg():
    """`0x47` alone is one random byte in 256 — `.ts` or a second sync byte decide."""
    einer = b"\x47" + b"\x00" * 15
    assert _pruefen("application/octet-stream", einer, "https://h.example/seg") is None
    assert _pruefen("application/octet-stream", einer, "https://h.example/seg1.ts") is not None
    paket = (b"\x47" + b"\x00" * 187) * 2
    assert _pruefen("application/octet-stream", paket, "https://h.example/seg") is not None


def test_eine_playlist_als_octet_stream_ist_hls(monkeypatch):
    """The content outranks the label — until now that list counted as a `datei`."""
    monkeypatch.setattr(probe, "_variante_traegt", lambda *a: True)
    fund = _pruefen("application/octet-stream", b"#EXTM3U\n#EXT-X-VERSION:3\n")
    assert fund is not None and fund.kind == "hls"


def test_eine_html_seite_ist_kein_film():
    """An expired address answered with 200 and an error page."""
    assert _pruefen("application/octet-stream", b"<!DOCTYPE html><html>") is None
    assert _pruefen("video/mp4", b"<html><body>abgelaufen") is None


def test_drm_wird_nur_auf_wunsch_geprueft(monkeypatch):
    """`probe()` asks "does it carry?"; only a caller that takes an address on
    its own asks "may we take it?" (`check_drm`)."""
    monkeypatch.setattr(probe, "_variante_traegt", lambda *a: True)
    liste = b'#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery"\n'

    class Voll(_Sitzung):
        def get(self, address, headers=None, **kw):
            antwort = super().get(address, headers, **kw)
            antwort.text = liste.decode()
            return antwort

    sitzung = Voll(_Antwort(200, "application/vnd.apple.mpegurl", liste))
    assert probe._probe(sitzung, "https://h.example/m.m3u8", {}) is not None
    with pytest.raises(probe.DrmError):
        probe._probe(sitzung, "https://h.example/m.m3u8", {}, check_drm=True)


def test_segmentverschluesselung_ist_keine_rechteverwaltung():
    """Word for word the app's rule: AES-128 with identity is ordinary encryption."""
    assert not probe._hls_hat_rechte('#EXT-X-KEY:METHOD=AES-128,URI="k",KEYFORMAT="identity"')
    assert not probe._hls_hat_rechte('#EXT-X-KEY:METHOD=AES-128,URI="k"')
    assert probe._hls_hat_rechte('#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x"')


def test_die_probe_selbst_fragt_mit_eigenem_ua_und_sagt_bei_drm_nein(monkeypatch):
    """`probe()` raises `DrmError` only from `_probe`; anything unforeseen counts as yes."""

    def kaputt(*a, **k):
        raise RuntimeError("unvorhergesehen")

    monkeypatch.setattr(probe, "_probe", kaputt)
    assert probe.probe("https://h.example/v.mp4") is True
    assert probe.probe("") is False


def test_der_beweis_fragt_sechzehn_bytes():
    sitzung = _Sitzung(_Antwort(206, "video/mp4", MP4))
    probe._probe(sitzung, "https://h.example/v.mp4", {})
    assert sitzung.gefragt[0]["Range"] == "bytes=0-15"
