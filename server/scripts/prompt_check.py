#!/usr/bin/env python3
"""Was im App-Prompt steht, gegen das, was der Server wirklich kann.

**Der Anlass, am 11.09.2026.** `docs/PROMPT-APP.md` beschreibt

    POST /redeem   {"code":"Y5NHU6", …}

Der Server erwartet `token`. Die App haette an ihrem einzigen Weg auf den
Fernseher einen 422 bekommen, und niemand haette es vor dem ersten Geraet
gemerkt.

Es ist derselbe Fehler wie in `scripts/walkthrough.py`, der acht Portale als
kaputt meldete, weil er `einstieg` statt `entry` fragte — nur teurer: Der
Prompt ist die Vorlage fuer A2, und was dort falsch steht, wird einmal
abgeschrieben und danach gesucht.

**Was geprueft wird.** Jeder Weg (`GET /p/{portal}/list`), der im Prompt
vorkommt, muss es im Server geben; jeder Parameter, den der Prompt in einem
Beispiel nennt, muss der Server kennen. Die Wahrheit ist `/openapi.json` —
FastAPI erzeugt es aus den Signaturen, es kann also nicht veralten.

**Was nicht geprueft wird:** Antwortfelder. Ihre Form steht im Prompt als
Mitschnitt vom laufenden Dienst, und ein Mitschnitt ist kein Vertrag.

    python scripts/prompt_check.py                      # gegen http://cl.example
    python scripts/prompt_check.py --basis http://127.0.0.1:8099
"""

from __future__ import annotations

import argparse
import json
import re
import ssl
import sys
import urllib.request
from pathlib import Path

WURZEL = Path(__file__).resolve().parent.parent
PROMPT = WURZEL / "docs" / "PROMPT-APP.md"

_OHNE_PRUEFUNG = ssl.create_default_context()
_OHNE_PRUEFUNG.check_hostname = False
_OHNE_PRUEFUNG.verify_mode = ssl.CERT_NONE

#: Ein Weg im Prompt: `GET /p/{portal}/list?entry=…` oder `POST /redeem   {…}`.
WEG = re.compile(r"^(GET|POST|PUT|DELETE|PATCH)\s+(/\S*)", re.M)

#: Wege, die es im Prompt gibt und die kein Endpunkt sind.
#:
#: Kurz halten: Jede Zeile hier ist ein Weg, den niemand mehr prueft.
NICHT_PRUEFEN = {
    "/?invite=",  # der Einladungslink zeigt auf den Leitstand, nicht auf die API
}


def _hol(basis: str, weg: str) -> dict:
    r = urllib.request.Request(basis + weg)
    with urllib.request.urlopen(r, timeout=20, context=_OHNE_PRUEFUNG) as a:
        return json.load(a)  # type: ignore[no-any-return]


def _muster(pfad: str) -> str:
    """`/p/zdf/list` → `/p/{portal_id}/list` — Beispielwerte zu Platzhaltern."""
    return re.sub(r"\{[^}]+\}", "{}", pfad)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--basis", default="https://cl.example")
    args = p.parse_args()

    text = PROMPT.read_text(encoding="utf-8")
    spec = _hol(args.basis.rstrip("/"), "/openapi.json")

    # Die Wege des Servers, auf Platzhalter normiert.
    echte: dict[str, dict] = {}
    for weg, arten in spec["paths"].items():
        echte[_muster(weg)] = arten

    befunde: list[str] = []

    for art, roh in WEG.findall(text):
        weg = roh.split("?")[0].rstrip(".,")
        if any(weg.startswith(x) for x in NICHT_PRUEFEN):
            continue
        # Beispielwerte wie `/p/zdf/list` auf `/p/{}/list` bringen: Jedes
        # Stueck, das im Server ein Platzhalter ist, wird hier einer.
        treffer = None
        for m, arten in echte.items():
            stuecke_m, stuecke_w = m.split("/"), weg.split("/")
            if len(stuecke_m) != len(stuecke_w):
                continue
            if all(a == "{}" or a == b for a, b in zip(stuecke_m, stuecke_w, strict=False)):
                treffer = (m, arten)
                break

        if treffer is None:
            befunde.append(f"{art} {weg} — kein solcher Weg im Server")
            continue

        m, arten = treffer
        if art.lower() not in arten:
            befunde.append(f"{art} {weg} — den Weg gibt es, aber nicht als {art}")
            continue

        # Suchparameter aus dem Beispiel.
        if "?" in roh:
            frage = roh.split("?", 1)[1]
            bekannt = {
                q["name"] for q in arten[art.lower()].get("parameters", []) if q["in"] == "query"
            }
            for teil in frage.split("&"):
                name = teil.split("=")[0].strip()
                if name and name not in bekannt:
                    befunde.append(
                        f"{art} {weg} — Parameter `{name}` kennt der Server nicht"
                        + (f" (er hat: {', '.join(sorted(bekannt))})" if bekannt else "")
                    )

        # Rumpf-Felder aus dem Beispiel: `POST /redeem   {"code":"…"}`
        zeile = next((z for z in text.split("\n") if z.startswith(f"{art} {roh}")), "")
        rumpf = re.search(r"\{.*\}", zeile)
        if rumpf and art.lower() in ("post", "put", "patch"):
            leib = arten[art.lower()].get("requestBody", {})
            verweis = (
                leib.get("content", {}).get("application/json", {}).get("schema", {}).get("$ref")
            )
            felder: set[str] = set()
            if verweis:
                name = verweis.rsplit("/", 1)[-1]
                felder = set(spec["components"]["schemas"].get(name, {}).get("properties", {}))
            for schluessel in re.findall(r'"(\w+)"\s*:', rumpf.group(0)):
                if felder and schluessel not in felder:
                    befunde.append(
                        f"{art} {weg} — Rumpffeld `{schluessel}` kennt der Server nicht"
                        f" (er hat: {', '.join(sorted(felder))})"
                    )

    if not befunde:
        print("Der Prompt deckt sich mit dem Server.")
        return 0

    print(f"{len(befunde)} Befunde:")
    for b in befunde:
        print("  " + b)
    return 1


if __name__ == "__main__":
    sys.exit(main())
