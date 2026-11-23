# Server contract

The app reads the CL server's answers in a fixed shape. These scripts keep that
shape honest whenever the server changes (AP85, 2026-11-09).

Both need a CL server checkout and a Python with its requirements:

    export CL_SOURCE=/path/to/cinelounge-server CL_PYTHON=/path/to/venv/bin/python

- `python3 record.py` starts a fresh server on a throw-away data dir, sets up a
  household (the adult role with the 18+ lock, a role "Admin" with 18+, a child)
  and writes the real answers of `/household/me` and `/household/joins` into
  `Packages/PortalKit/Tests/PortalKitTests/Mitschnitte`. The app's tests decode
  them — if the server changes the answer, they turn red.
- `python3 app_against_server.py` starts such a server and runs the app's live
  suite `RolesLiveTests` against it: a person in the locked adult role signs in
  a phone of her own, a child gets no mark, and an approval by role id with the
  console makes an administrator with 18+. It also checks the device kinds the
  server recorded (`phone`, `tablet`).

`launch_server.py` only tolerates `setrlimit` failing on macOS; nothing else
differs from production.
