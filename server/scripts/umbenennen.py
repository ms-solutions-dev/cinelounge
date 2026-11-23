#!/usr/bin/env python3
"""Bezeichner umbenennen — ueber `tokenize`, nicht ueber Suchen-und-Ersetzen.

**Warum `tokenize` und nicht `re.sub`.** In diesem Quelltext heisst eine
Variable `an` und ein deutscher Kommentar enthaelt das Wort „an" zwanzigmal.
Ein Ersetzen mit Wortgrenzen traefe beide. `tokenize` gibt jede Marke mit ihrem
Typ zurueck: NAME wird uebersetzt, COMMENT und STRING nicht.

**Was es ausdruecklich nicht kann.** Zeichenketten, die Bezeichner enthalten:

    laeufer.rufe(m, "liste", {"einstieg": …})   # Schluessel = Parametername
    getattr(portal, methode)                     # Methodenname zur Laufzeit

Die stehen danach falsch und muessen von Hand nachgezogen werden. Der Aufruf
mit `--zeichenketten` listet die Verdaechtigen auf, statt sie zu raten.

    python scripts/umbenennen.py --trocken     # nur zeigen
    python scripts/umbenennen.py               # schreiben
    python scripts/umbenennen.py --zeichenketten
"""

from __future__ import annotations

import io
import sys
import token
import tokenize
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scripts.karte import alles

WURZEL = Path(__file__).resolve().parent.parent

#: Attrappen bilden eine fremde Schnittstelle nach. Ihre Namen heissen so,
#: wie fremder Code sie ruft — dort wird nichts umbenannt ausser dem, was
#: uns gehoert.
NICHT_ANFASSEN = {"attrappen.py"}


def dateien() -> list[Path]:
    heraus = []
    for muster in ("cinelounge/**/*.py", "scripts/*.py", "tests/*.py", "portale/**/*.py"):
        heraus += [p for p in WURZEL.glob(muster) if "__pycache__" not in p.parts]
    return sorted(set(heraus))


def umschreiben(quelle: str, karte: dict[str, str]) -> tuple[str, int]:
    """Nur NAME-Marken ersetzen. Gibt den neuen Text und die Zahl der Treffer."""
    # **Import-Zeilen bleiben unberuehrt.** Dort stehen Modulnamen, und die
    # zieht der Datei-Umzug nach — `kennung` ist als Feld `ident` und als Modul
    # `ids`, und nur die Zeile sagt, welches gemeint ist.
    einfuhr = {
        n
        for n, z in enumerate(quelle.splitlines(), 1)
        if z.lstrip().startswith(("import ", "from "))
    }
    marken = list(tokenize.generate_tokens(io.StringIO(quelle).readline))
    treffer = 0
    neu = []
    for m in marken:
        if m.start[0] in einfuhr:
            neu.append(m)
        elif m.type == token.NAME and m.string in karte:
            treffer += 1
            neu.append(m._replace(string=karte[m.string]))
        else:
            neu.append(m)
    return tokenize.untokenize(neu), treffer


def verdaechtige_zeichenketten(karte: dict[str, str]) -> list[str]:
    """Zeichenketten, die wie ein umbenannter Bezeichner aussehen.

    Sie sind der einzige Teil, den der Umschreiber nicht sehen kann — und
    genau dort sitzen die Fehler, die erst zur Laufzeit auffallen.
    """
    heraus = []
    for datei in dateien():
        if datei.name in ("karte.py", "umbenennen.py"):
            continue
        quelle = open(datei, encoding="utf-8").read()
        try:
            marken = tokenize.generate_tokens(io.StringIO(quelle).readline)
            for m in marken:
                if m.type != token.STRING:
                    continue
                roh = m.string.strip("\"'")
                if roh in karte and len(roh) > 2:
                    heraus.append(
                        f"{datei.relative_to(WURZEL)}:{m.start[0]}  {m.string}"
                        f"  →  vermutlich {karte[roh]!r}"
                    )
        except tokenize.TokenError:
            continue
    return heraus


def main() -> int:
    karte = alles()
    if "--zeichenketten" in sys.argv:
        for z in verdaechtige_zeichenketten(karte):
            print("  " + z)
        return 0

    trocken = "--trocken" in sys.argv
    gesamt = 0
    for datei in dateien():
        if datei.name in NICHT_ANFASSEN or datei.name in ("karte.py", "umbenennen.py"):
            continue
        quelle = open(datei, encoding="utf-8").read()
        try:
            neu, treffer = umschreiben(quelle, karte)
        except tokenize.TokenError as fehl:
            print(f"  ! {datei.relative_to(WURZEL)}: {fehl}")
            continue
        if not treffer:
            continue
        gesamt += treffer
        print(f"  {treffer:4d}  {datei.relative_to(WURZEL)}")
        if not trocken:
            open(datei, "w", encoding="utf-8", newline="\n").write(neu)
    print(f"{gesamt} Marken{' (trocken)' if trocken else ''}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
