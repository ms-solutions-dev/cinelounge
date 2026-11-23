#!/usr/bin/env python3
"""M4 · Does the direct path to the host hold, or must the stream go through the bridge?

**Why the question stands differently on the phone than on the TV.** Since 29.08.
the bridge hands out every video address as a pass-through, for every portal.
Its own rationale stands in `portale-bruecke/kern/haupt.py` at `_ziel` and is
correct on the TV:

    "The price is bandwidth in the home network — not in the tunnel, the
    Apple TV sits in the same network."

Exactly this sentence does not hold on the phone. On the road the stream then
runs host → home server → WireGuard → phone, and the tunnel carries a measured
0.31 Mbit/s. The ARD file from the last pass was 2,389 MB.

**What this script measures and what it does not.** It measures what can be
decided from outside the container at all:

  * How many addresses point to the container itself (`127.0.0.1`)? For those the
    direct path is not difficult but impossible — no setting helps there.
  * Of the rest: does the host answer from here? Over IPv4, over IPv6, with and
    without the headers the bridge passes along?

It does **not** measure what the TV or the phone sees — and that is the core of
`_ziel`: "In the IPv6 case the container gets 200 and the Apple TV 403, at the
same address in the same second." The last number for M4 can therefore only come
from the app (AP14). This script narrows down how big the remainder can still be.

    python3 scripts/measure-portal-path.py                # all portals
    python3 scripts/measure-portal-path.py ard serieshub
"""

from __future__ import annotations

import json
import subprocess
import sys
import urllib.parse
import urllib.request

BRIDGE = "http://bruecke.example:8099"
TIMEOUT = 30
SOURCES_PER_PORTAL = 3

GREEN, RED, YELLOW, GRAY, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[90m", "\033[0m"


def fetch(path: str, **query) -> dict:
    address = f"{BRIDGE}{path}?{urllib.parse.urlencode(query)}"
    with urllib.request.urlopen(address, timeout=120) as reply:
        return json.load(reply)


def playable_entry(portal: str) -> dict:
    """Down from the menu until an entry has no children left.

    The same path as `werkzeug.durchgang` in the container — "New episodes" leads
    to an episode the shortest way, one step instead of three.
    """
    entries = fetch(f"/p/{portal}/menu")["einstiege"]
    preferred = [e for e in entries if "Folgen" in e["name"]] or entries
    items = fetch(f"/p/{portal}/liste", einstieg=preferred[0]["id"])["items"]
    if not items:
        raise RuntimeError("empty list")

    entry, levels = items[0], 0
    while entry.get("hat_kinder") and levels < 3:
        children = fetch(f"/p/{portal}/kinder", adresse=entry["adresse"], titel=entry["titel"])
        if not children["items"]:
            break
        entry, levels = children["items"][0], levels + 1
    return entry


def real_address(pass_through: str) -> str:
    """Pull the host address out of the pass-through.

    The bridge wraps it as `/strom?adresse=<encoded>`. If nothing stands there,
    the address was direct already.
    """
    parts = urllib.parse.urlsplit(pass_through)
    inner = urllib.parse.parse_qs(parts.query).get("adresse")
    return inner[0] if inner else pass_through


def probe(address: str, family: str, headers: dict | None) -> tuple[str, int]:
    """Fetch a byte range from the host. Returns (finding, size in MB).

    A range is fetched instead of a HEAD: some hosts answer HEAD with 405 and
    still serve on a GET.
    """
    command = [
        "curl", "-s", "-o", "/dev/null", f"--{family}",
        "--max-time", str(TIMEOUT),
        "-r", "0-1023",
        "-w", "%{http_code} %{size_download} %{header_json}",
        address,
    ]
    for name, value in (headers or {}).items():
        command[1:1] = ["-H", f"{name}: {value}"]

    run = subprocess.run(command, capture_output=True, text=True)
    if run.returncode != 0:
        return f"curl {run.returncode}", 0
    head, _, rest = run.stdout.partition(" ")
    _, _, headers_json = rest.partition(" ")
    mb = 0
    try:
        fields = json.loads(headers_json)
        byte_range = fields.get("content-range", [""])[0]
        if "/" in byte_range:
            mb = int(byte_range.rsplit("/", 1)[1]) // 1048576
    except (json.JSONDecodeError, ValueError, IndexError):
        pass
    return head, mb


def measure(portal: str) -> list[dict]:
    print(f"\n══ {portal}")
    entry = playable_entry(portal)
    print(f"   Target  : {entry['titel']}")

    sources = fetch(f"/p/{portal}/quellen", adresse=entry["adresse"], titel=entry["titel"])["quellen"]
    findings = []

    for source in sources[:SOURCES_PER_PORTAL]:
        # Catch per source: a host the bridge cannot resolve is a finding and
        # no reason to lose the remaining sources of the same portal.
        try:
            result = fetch("/play", portal=portal, quelle=source["id"], weiterleiten="false")
        except Exception as error:  # noqa: BLE001
            findings.append({"portal": portal, "source": source["name"], "host": "—",
                             "verdict": "bridge cannot resolve"})
            print(f"   {RED}✗{OFF} {source['name']:<28} {GRAY}Bridge: "
                  f"{str(error)[:60]}{OFF}")
            continue
        target = real_address(result["adresse"])
        host = urllib.parse.urlsplit(target).hostname or "?"
        headers = result.get("kopfzeilen") or {}

        finding = {"portal": portal, "source": source["name"], "host": host}

        if host in ("127.0.0.1", "localhost", "::1"):
            # A proxy the portal starts in the container. For every device
            # outside, this address points to the device itself.
            finding["verdict"] = "in the container"
            print(f"   {RED}✗{OFF} {source['name']:<28} {host:<22} "
                  f"{GRAY}address in the container — direct path impossible{OFF}")
        else:
            v4, mb = probe(target, "ipv4", headers)
            v6, _ = probe(target, "ipv6", headers)
            without, _ = probe(target, "ipv4", None) if headers else (v4, 0)
            finding |= {"v4": v4, "v6": v6, "without_headers": without, "mb": mb}
            holds = v4.startswith("2")
            finding["verdict"] = "direct" if holds else f"IPv4 {v4}"
            mark = f"{GREEN}✓{OFF}" if holds else f"{RED}✗{OFF}"
            header_note = "" if not headers else (
                f" · without headers {without}" if without != v4 else " · headers irrelevant"
            )
            print(f"   {mark} {source['name']:<28} {host:<22} "
                  f"IPv4 {v4} · IPv6 {v6} · {mb} MB{header_note}")

        findings.append(finding)
    return findings


def main() -> int:
    portals = sys.argv[1:] or [
        p["id"] for p in fetch("/portale")["portale"] if p["aktiv"] and p["zustand"] == "bereit"
    ]

    every: list[dict] = []
    for portal in portals:
        try:
            every += measure(portal)
        except Exception as error:  # noqa: BLE001 — every failure is a finding here
            print(f"   {RED}✗{OFF} {type(error).__name__}: {str(error)[:160]}")

    print("\n" + "═" * 68)
    if not every:
        print("Nothing measured.")
        return 1

    container = sum(1 for b in every if b["verdict"] == "in the container")
    direct = sum(1 for b in every if b["verdict"] == "direct")
    unresolved = sum(1 for b in every if b["verdict"] == "bridge cannot resolve")
    print(f"  {len(every)} sources checked")
    print(f"  {direct} hold directly from here")
    print(f"  {container} point into the container — there is no direct path for those")
    print(f"  {unresolved} the bridge could not even resolve")
    print(f"  {len(every) - direct - container - unresolved} do not answer from here")
    print(f"\n{GRAY}  Measured from this machine, not from the phone. What a device{OFF}")
    print(f"{GRAY}  with IPv6 sees at the same address can differ — that is exactly{OFF}")
    print(f"{GRAY}  why the bridge has passed everything through since 29.08.{OFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
