"""Wem der Dienst die Herkunft einer Anfrage glaubt.

Die Drossel auf `/join` und `/device/enroll` geht je Adresse, und der Verwalter
sieht bei jeder Anfrage, woher sie kam. Beides liest `request.client.host` —
und das setzt uvicorn aus `X-Forwarded-For`, sobald es dem Absender als Proxy
glaubt. Mit `"*"` koennte jeder den Kopf mitschicken und sich je Versuch eine
neue Herkunft ausdenken.

Die Vorgabe im Abbild glaubt nur der eigenen Maschine; wer einen Reverse Proxy
davorstellt, setzt `FORWARDED_ALLOW_IPS` in seiner Compose-Datei.
"""

from __future__ import annotations

import re
import shlex
from pathlib import Path

from uvicorn.middleware.proxy_headers import _TrustedHosts

DOCKERFILE = Path(__file__).resolve().parent.parent / "Dockerfile"


def _vertraut() -> str:
    """Was der Dienst im Abbild als Proxy glaubt — Schalter vor Umgebung, wie uvicorn."""
    text = DOCKERFILE.read_text(encoding="utf-8")
    cmd = [z for z in text.splitlines() if z.startswith("CMD [")][-1]
    teile = re.findall(r'"([^"]*)"', cmd)
    if "--forwarded-allow-ips" in teile:
        return teile[teile.index("--forwarded-allow-ips") + 1]
    env = re.findall(r"^ENV FORWARDED_ALLOW_IPS=(.+)$", text, re.MULTILINE)
    return shlex.split(env[-1])[0] if env else "127.0.0.1"


def test_niemand_von_aussen_kann_sich_eine_herkunft_ausdenken():
    t = _vertraut()
    assert t.strip() != "*", "jedem glauben heißt: jeder wählt seine Herkunft"
    glaube = _TrustedHosts(t)
    for fremd in ("192.168.1.28", "10.8.0.2", "172.17.0.1", "172.16.0.7"):
        assert fremd not in glaube, fremd


def test_die_vorgabe_glaubt_nur_der_eigenen_maschine():
    assert "127.0.0.1" in _TrustedHosts(_vertraut())
