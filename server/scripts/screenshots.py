#!/usr/bin/env python3
"""The console in a real browser — screenshots, console log, overflow.

**Why this is needed.** `tests/test_console.py` checks the routes and the
markup: does every view hang on the frame, does every id occur exactly once,
does every import find its export. That is a lot and still only the DOM. No
JavaScript runs, nothing is drawn, and a CSS rule that makes a tile invisible
never shows in it — the fault of 10.09.2026 was exactly that.

**What this pass sees in addition:**

- Every uncaught console error, every `pageerror` — and every **rejected
  promise** nobody catches. The last was retrofitted: Chromium sends them as
  `unhandledrejection`, and in an interface that fetches its data with `await`
  that is precisely the normal case.
- Requests that return 4xx/5xx or never arrive.
- Horizontal overflow. On a phone that is the most common layout fault, and it
  is mechanically unambiguous: whoever draws wider than the window has one.
- Visible areas without height — a tile with text and 0 px.
- **And what stands on the pictures.** The first run on 11.09.2026 reported
  zero findings and still showed "Abgeschaltet heisst nicht **remove**" and
  "ob ein Portal ueberhaupt **on** Geraete geht" — prose damage in the markup
  no check can recognise as an error. That is what the pictures are for.

**What it expressly does not see: caught errors.** `core/memory.js` read
`vorgabe` instead of `fallback` — a parameter the renamer renamed without
carrying the usage along. The `ReferenceError` landed in the `catch` around
it, the browser quietly remembered nothing any more, and the console stayed
clean. A `try` around a typo is invisible to this pass.

**What it cannot do.** Tell whether something is *pretty*. The pictures lie in
`--out` afterwards and want to be looked at.

The PIN comes from `CL_PIN` in the environment or from `--pin` — never from a
default in this file: a household PIN has no place in a repository.

    CL_PIN=1234 python scripts/screenshots.py
    python scripts/screenshots.py --basis http://127.0.0.1:8099 --pin 1234
    python scripts/screenshots.py --out /tmp/bilder --breite 1440
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

#: The navigation's views, in the order of the bar.
#:
#: `portal` is missing on purpose: the detail page has no button, it is opened
#: from the portal list. It gets its turn further down.
ANSICHTEN = [
    "overview",
    "portals",
    "market",
    "household",
    "devices",
    "network",
    "workshop",
    "settings",
]

#: Width, height and name per format.
FORMATE = [(1440, 900, "breit"), (390, 844, "telefon")]

#: Console messages that are no finding.
#:
#: Keep it short. Every line here is a message that never shows again — too
#: long a list makes the pass green and worthless.
LEISE = (
    "Download the React DevTools",
    "favicon.ico",
)


#: The service runs behind a self-issued certificate.
#:
#: `deploy.sh` does the same with `curl -sk`, and the app accepts it likewise in
#: `CertificateTrust.swift`. A pass on the home network is not the place to
#: enforce a certificate chain — the browser below gets `ignore_https_errors`
#: for the same reason.
_OHNE_PRUEFUNG = ssl.create_default_context()
_OHNE_PRUEFUNG.check_hostname = False
_OHNE_PRUEFUNG.verify_mode = ssl.CERT_NONE


def anmelden(basis: str, name: str, pin: str) -> str:
    """Fetch the device token over the API instead of typing it in.

    Clicking through the login form would be the more honest way and the less
    reliable one: it has a number field, a person picker and an error display,
    and every change to those would break this pass. The token is the same no
    matter where it comes from.
    """
    leib = json.dumps({"name": name, "pin": pin}).encode()
    r = urllib.request.Request(
        basis + "/login", data=leib, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(r, timeout=20, context=_OHNE_PRUEFUNG) as a:
            return str(json.load(a)["device_token"])
    except urllib.error.HTTPError as err:
        raise SystemExit(f"login refused ({err.code}) — is --pin right?") from err
    except OSError as err:
        raise SystemExit(f"{basis} does not answer: {err}") from err


def _pruefe_layout(seite: Any, breite: int) -> list[str]:
    """What can be measured on the drawn picture.

    Both with tolerance: one pixel of overflow is rounding, not an error, and an
    empty container without text is structure and not a broken tile.
    """
    return list(
        seite.evaluate(
            """(breite) => {
        const klagen = [];
        if (document.documentElement.scrollWidth > breite + 2) {
          klagen.push('horizontal overflow: ' +
            document.documentElement.scrollWidth + ' px at ' + breite + ' px window');
        }
        for (const el of document.querySelectorAll('#main *')) {
          const r = el.getBoundingClientRect();
          const text = (el.textContent || '').trim();
          if (!text || r.width === 0) continue;
          const stil = getComputedStyle(el);
          if (stil.display === 'none' || stil.visibility === 'hidden') continue;
          if (r.height === 0) {
            klagen.push('no height but text: ' +
              el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') +
              ' — "' + text.slice(0, 40) + '"');
          }
        }
        return klagen.slice(0, 8);
      }""",
            breite,
        )
    )


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    # **`https`, not `http`.** Traefik answers `http://cl.example` with a 308 to
    # the secured address, and `urllib` does not carry a POST's body there. The
    # call without arguments therefore failed at login — with the message "is
    # --pin right?", which points in the wrong direction.
    p.add_argument("--basis", default="https://cl.example", help="root of the service")
    p.add_argument("--name", default=os.environ.get("CL_NAME", "admin"))
    # **No default for the PIN.** It stood here as `0609` until 12.09.2026 —
    # the household's real admin PIN, in a repository meant to be handed to
    # strangers. The environment is the place for it, or the command line.
    p.add_argument("--pin", default=os.environ.get("CL_PIN", ""))
    p.add_argument("--out", default="bilder", help="where the pictures go")
    p.add_argument("--breite", type=int, help="only this format")
    p.add_argument("--muster", default="both", choices=["light", "dark", "both"])
    args = p.parse_args()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise SystemExit(
            "playwright missing. `pip install playwright && playwright install chromium`"
        ) from None

    if not args.pin:
        raise SystemExit("no PIN: set CL_PIN in the environment or pass --pin")
    basis = args.basis.rstrip("/")
    merkmal = anmelden(basis, args.name, args.pin)
    ziel = Path(args.out)
    ziel.mkdir(parents=True, exist_ok=True)

    formate = [f for f in FORMATE if not args.breite or f[0] == args.breite]
    # **A pass without a format is no pass.** `--breite 430` matched neither
    # of the two and ran through quietly: "0 pictures in … · no findings" —
    # the same kind of green promise this script exists to end.
    if not formate:
        moeglich = ", ".join(str(f[0]) for f in FORMATE)
        raise SystemExit(f"--breite {args.breite} does not exist. Available: {moeglich}")
    muster = ["light", "dark"] if args.muster == "both" else [args.muster]

    befunde: list[str] = []
    bilder = 0

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        for breite, hoehe, formatname in formate:
            for wahl in muster:
                kontext = browser.new_context(
                    viewport={"width": breite, "height": hoehe},
                    color_scheme=wahl,
                    ignore_https_errors=True,
                )
                seite = kontext.new_page()

                # Record before anything loads.
                konsole: list[str] = []
                # **`konsole` is a different list per pass**, and the lambdas
                # capture the variable rather than its value. Formally that is
                # B023; in practice every iteration closes its page before the
                # next begins — there are never two live pages that could
                # share a list.
                seite.on(
                    "console",
                    lambda m: (
                        konsole.append(f"{m.type}: {m.text}")  # noqa: B023
                        if m.type == "error" and not any(x in m.text for x in LEISE)
                        else None
                    ),
                )
                seite.on(
                    "pageerror",
                    lambda e: konsole.append(f"pageerror: {e}"),  # noqa: B023
                )
                # **A rejected promise is no `pageerror`.**
                #
                # Measured 11.09.2026: `buildSidebarCard()` called a `setz`
                # that is local to a function further up. The `ReferenceError`
                # landed in the promise of `boot()`, the service box showed
                # three dashes — and this pass reported "no findings".
                #
                # Chromium sends such a thing to the window as
                # `unhandledrejection`, not as `pageerror`. In an interface
                # that fetches its data with `await` that is the normal case
                # and not the exception.
                seite.add_init_script(
                    "addEventListener('unhandledrejection', (e) => {"
                    "  console.error('unhandledrejection: ' + (e.reason && e.reason.stack"
                    "    ? e.reason.stack.split('\\n')[0] : e.reason));"
                    "});"
                )
                seite.on(
                    "requestfailed",
                    lambda r: (
                        konsole.append(f"request failed: {r.url}")  # noqa: B023
                        if not any(x in r.url for x in LEISE)
                        else None
                    ),
                )
                seite.on(
                    "response",
                    lambda r: (
                        konsole.append(f"HTTP {r.status}: {r.url}")  # noqa: B023
                        if r.status >= 400 and not any(x in r.url for x in LEISE)
                        else None
                    ),
                )

                # Store token and theme before the page runs — otherwise it
                # shows the login first and reloads afterwards.
                seite.add_init_script(
                    f"window.localStorage.setItem('cl.token', {json.dumps(json.dumps(merkmal))});"
                    f"window.localStorage.setItem('cl.theme', {json.dumps(json.dumps(wahl))});"
                )
                seite.goto(basis + "/", wait_until="networkidle", timeout=45000)

                for ansicht in ANSICHTEN:
                    vorher = len(konsole)
                    knopf = seite.locator(f'.nav-button[data-zu="{ansicht}"]')
                    if knopf.count() == 0:
                        befunde.append(f"{ansicht}: no button in the bar")
                        continue
                    if not knopf.is_visible():
                        # No finding: the bar hides what the role may not do.
                        # Which role that is, test_console checks.
                        continue
                    knopf.click()
                    seite.wait_for_timeout(350)

                    name = f"{ansicht}-{formatname}-{wahl}.png"
                    seite.screenshot(path=str(ziel / name), full_page=True)
                    bilder += 1

                    for klage in _pruefe_layout(seite, breite):
                        befunde.append(f"{ansicht} [{formatname}]: {klage}")
                    for zeile in konsole[vorher:]:
                        befunde.append(f"{ansicht} [{formatname}/{wahl}]: {zeile}")

                kontext.close()
        browser.close()

    print(f"{bilder} pictures in {ziel}/")
    if not befunde:
        print("No findings.")
        return 0

    print(f"\n{len(befunde)} findings:")
    for b in befunde:
        print("  " + b)
    return 1


if __name__ == "__main__":
    sys.exit(main())
