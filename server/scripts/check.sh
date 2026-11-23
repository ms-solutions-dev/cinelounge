#!/usr/bin/env bash
# Ein Aufruf prueft alles. Erst wenn er durchlaeuft, wird eingecheckt.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "── Formatieren ─────────────────────────────"; ruff format .
echo "── Pruefen ─────────────────────────────────"; ruff check .
echo "── Schichten ───────────────────────────────"; lint-imports
echo "── Typen ───────────────────────────────────"; mypy --strict cinelounge
echo "── Testen ──────────────────────────────────"; pytest -q
# Wer eigene Erweiterungen pflegt, legt deren Pruefungen in `checks.local.sh`
# neben `pyproject.toml`. Sie laufen hier mit, damit ein Aufruf weiter alles
# prueft; ohne die Datei aendert sich nichts.
if [ -f checks.local.sh ]; then
    echo "── Eigene Pruefungen ───────────────────────"; bash checks.local.sh
fi
echo
echo "Alles durch."
