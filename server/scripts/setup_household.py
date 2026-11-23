#!/usr/bin/env python3
"""First run: create the household.

Runs inside the container at startup and does **nothing** if somebody is
already there — the first run must not be a step backwards.

    docker compose run --rm cinelounge python scripts/setup_household.py \\
        --name Alex --pin 1234

Without `--pin` a PIN is rolled and written to the log. That is the safe way
for a stranger self-hosting: there is no window in which the service stands
open, and the code stands where only somebody with access to the container
looks anyway.
"""

from __future__ import annotations

import argparse
import os
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cinelounge.household.people import People
from cinelounge.household.store import Store


def main() -> int:
    p = argparse.ArgumentParser(description="Haushalt anlegen")
    p.add_argument("--name", default="Admin")
    p.add_argument("--pin", default="")
    p.add_argument("--haus", default="CineLounge", help="Name des Haushalts")
    p.add_argument("--daten", default=os.environ.get("CL_DATA", "/data"))
    a = p.parse_args()

    store = Store(Path(a.daten) / "household.sqlite")
    people = People(store)

    if not people.is_empty():
        current_person = ", ".join(x.name for x in people.list_all())
        print(f"Household already exists: {current_person} - nothing to do.")
        return 0

    pin = a.pin or "".join(secrets.choice("0123456789") for _ in range(6))
    person = people.create(a.name, "admin", pin, color="#E2564A")
    store.write("haus.name", a.haus)

    # ASCII only: these lines land in the container log, and `docker logs`
    # sometimes runs through a console that cannot do UTF-8.
    print("=" * 62)
    print(f"  Household '{a.haus}' created.")
    print(f"  Admin : {person.name}  (id {person.id})")
    if not a.pin:
        print(f"  PIN   : {pin}      <- shown once, write it down")
    else:
        print("  PIN   : as given")
    print("=" * 62)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
