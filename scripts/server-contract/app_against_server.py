"""App against a fresh local CL server: roles as data (AP85 #57).

Starts the server from the clone on a throw-away data dir, sets up a household
(Max admin, the adult role with the 18+ lock, Sina in it, a child), hands two
invitations to the app's live test and checks afterwards which device kinds the
server recorded.
"""

import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx

HERE = Path(__file__).parent
CLONE = Path(os.environ["CL_SOURCE"])  # a CL server checkout
PY = Path(os.environ.get("CL_PYTHON", sys.executable))  # with its requirements
APP = HERE.parent.parent  # this repo
PIN = "4711"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


data = Path(tempfile.mkdtemp(prefix="cl-e2e-"))
port = free_port()
log = open(data / "server.log", "w+")
env = dict(os.environ, CL_DATA=str(data), PYTHONPATH=str(CLONE), PYTHONUTF8="1")
server = subprocess.Popen(
    [str(PY), str(HERE / "launch_server.py"), str(port)], cwd=CLONE, env=env, stdout=log, stderr=log
)
base = f"http://127.0.0.1:{port}"
ok = True
try:
    code = None
    for _ in range(100):
        time.sleep(0.2)
        log.seek(0)
        m = re.search(r"Setup code:\s+(\S+)", log.read())
        if m:
            code = m.group(1)
            break
    assert code, "no setup code in the server log"

    r = httpx.post(base + "/setup", json={"code": code, "name": "Max", "pin": PIN})
    assert r.status_code == 200, r.text
    max = {"X-CL-Device": r.json()["device_token"]}

    def post(path, body):
        r = httpx.post(base + path, json=body, headers=max)
        assert r.status_code in (200, 201), f"{path}: {r.status_code} {r.text}"
        return r.json()

    post("/household/roles/adult/child_lock", {"on": True, "my_pin": PIN})
    sina = post("/household/people", {"name": "Sina", "role": "adult"})
    emir = post("/household/people", {"name": "Eli", "role": "child"})
    sina_id = sina.get("id") or sina["person"]["id"]
    emir_id = emir.get("id") or emir["person"]["id"]
    inv_sina = post("/household/invite", {"person": sina_id})["token"]
    # Children get no invitation link (`invite.not_for_children`): the admin pairs
    # the device with a code assigned to the child.
    inv_emir = post("/household/devices/code", {"name": "Live check child", "kind": "tablet"})["code"]
    post(f"/household/pending/{inv_emir}/person", {"person": emir_id})

    post("/household/roles", {"name": "Admin", "color": "#E2564A",
         "rights": ["watch", "track_progress", "view_adult", "own_devices", "invite"]})
    httpx.post(base + "/join", json={"name": "Selin", "color": "#4A90D9", "device": "Selins iPhone",
               "kind": "phone", "want": ["portals"]}).raise_for_status()
    test_env = dict(os.environ, CL_SERVER=base, CL_INVITE=inv_sina, CL_INVITE_CHILD=inv_emir,
                    CL_ADMIN_TRAIT=max["X-CL-Device"], CL_ADMIN_PIN=PIN)
    out = subprocess.run(
        ["swift", "test", "--filter", "RolesLiveTests"],
        cwd=APP / "Packages" / "PortalKit", env=test_env, capture_output=True, text=True,
    )
    lines = [ln for ln in (out.stdout + out.stderr).splitlines() if re.search(r"✔|✘|Test run|error:", ln)]
    print("\n".join(lines[-12:]))
    ok &= out.returncode == 0

    devices = httpx.get(base + "/household/devices", headers=max).json()
    items = devices.get("devices") or devices.get("items") or []
    kinds = {(d.get("name"), d.get("kind")) for d in items}
    print("devices:", sorted(kinds, key=str))
    ok &= ("Live check phone", "phone") in kinds and ("Live check child", "tablet") in kinds
finally:
    server.terminate()
    server.wait(timeout=10)
    shutil.rmtree(data, ignore_errors=True)

print("E2E", "GREEN" if ok else "RED")
sys.exit(0 if ok else 1)
