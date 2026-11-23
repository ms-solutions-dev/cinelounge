"""Record real responses of the CL server for the app's contract tests (AP85 #78)."""
import json, os, re, shutil, socket, subprocess, sys, tempfile, time
from pathlib import Path
import httpx

HERE = Path(__file__).parent
CLONE = Path(os.environ["CL_SOURCE"]); PY = Path(os.environ.get("CL_PYTHON", sys.executable))
OUT = HERE.parent.parent / "Packages/PortalKit/Tests/PortalKitTests/Mitschnitte"; PIN = "1234"

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); return s.getsockname()[1]

data = Path(tempfile.mkdtemp(prefix="cl-rec-")); port = free_port()
log = open(data / "server.log", "w+")
env = dict(os.environ, CL_DATA=str(data), PYTHONPATH=str(CLONE), PYTHONUTF8="1")
server = subprocess.Popen([str(PY), str(HERE / "launch_server.py"), str(port)],
                          cwd=CLONE, env=env, stdout=log, stderr=log)
base = f"http://127.0.0.1:{port}"
try:
    code = None
    for _ in range(100):
        time.sleep(0.2); log.seek(0)
        m = re.search(r"Setup code:\s+(\S+)", log.read())
        if m: code = m.group(1); break
    r = httpx.post(base + "/setup", json={"code": code, "name": "Max", "pin": PIN}); r.raise_for_status()
    head = {"X-CL-Device": r.json()["device_token"]}
    def post(path, body, h=head):
        r = httpx.post(base + path, json=body, headers=h); assert r.status_code < 300, (path, r.text); return r.json()
    post("/household/roles", {"name": "Admin", "color": "#E2564A",
         "rights": ["watch", "track_progress", "view_adult", "own_devices", "invite"]})
    post("/household/roles/adult/child_lock", {"on": True, "my_pin": PIN})
    sina = post("/household/people", {"name": "Sina", "role": "adult"})
    inv = post("/household/invite", {"person": sina.get("id") or sina["person"]["id"]})["token"]
    s = httpx.post(base + "/redeem", json={"token": inv, "name": "Sinas iPhone", "kind": "phone"}).json()
    me = httpx.get(base + "/household/me", headers={"X-CL-Device": s["device_token"]}).json()
    httpx.post(base + "/join", json={"name": "Selin", "color": "#4A90D9", "device": "Selins iPhone",
               "kind": "phone", "want": ["portals"]}).raise_for_status()
    joins = httpx.get(base + "/household/joins", headers=head).json()
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "household-me-roles.json").write_text(json.dumps(me, indent=2, ensure_ascii=False) + "\n")
    (OUT / "household-joins-roles.json").write_text(json.dumps(joins, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(me)); print(json.dumps(joins)[:900])
finally:
    server.terminate(); server.wait(timeout=10); shutil.rmtree(data, ignore_errors=True)
