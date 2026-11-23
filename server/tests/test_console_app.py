"""The console (React app in `console-app/`) against the server — rebuild 09.11.2026.

Replaces the checks that read the old console's JavaScript: the console's
calls must hit real routes, every sentence it asks for must exist in all three
languages, and every code the server sends must have a sentence. The build is
not needed for these; they read the sources.

**Only the core's sources** (`src/` without `src/extension/local/`) and the
core's languages: that is what this project builds. A console extension (see
`src/extension/types.ts`) brings its own checks; the helpers here take its
folder and its languages, so it can run the same ones over core plus extension.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "console-app" / "src"
LANGS = APP / "languages"
LANGUAGES = ("de", "en", "tr")
#: Where a local extension is built from; not part of the core's sources.
LOCAL = APP / "extension" / "local"


def _flat(d: dict, prefix: str = "") -> set[str]:
    out: set[str] = set()
    for k, v in d.items():
        out |= _flat(v, f"{prefix}{k}.") if isinstance(v, dict) else {prefix + k}
    return out


def _lang(code: str) -> dict:
    return json.loads((LANGS / f"{code}.json").read_text(encoding="utf-8"))


def _sources(*extra: Path) -> str:
    """The core's TypeScript, plus the folders given (an extension's)."""
    core = [p for p in APP.rglob("*.ts*") if LOCAL not in p.parents]
    more = [p for d in extra for p in d.rglob("*.ts*")]
    return "\n".join(p.read_text(encoding="utf-8") for p in core + more)


def _used_keys(text: str) -> set[str]:
    return set(re.findall(r'["`](ui\.[a-z_]+\.[a-z_0-9]+(?:\.[a-z_0-9]+)?)["`]', text))


def _calls(text: str) -> set[str]:
    """The server paths the console calls, `${…}` as `x`."""
    calls: set[str] = set()
    for m in re.finditer(
        r'["`](/(?:household|network|login|setup|logout|redeem|health|join|search|play|p/)[^"`?]*)',
        text,
    ):
        calls.add(re.sub(r"\$\{[^}]+\}", "x", m.group(1)).rstrip("/"))
    return calls


def _route_patterns() -> list[re.Pattern[str]]:
    """Every route of the service as it is loaded now (with or without extension)."""
    import importlib

    from cinelounge.web import main

    importlib.reload(main)
    return [
        re.compile("^" + re.sub(r"\{[^}]+\}", "[^/]+", r.path) + "$")
        for r in main.app.routes
        if getattr(r, "path", None)
    ]


@pytest.mark.parametrize("code", ["en", "tr"])
def test_every_language_is_complete(code):
    """Both directions: nothing missing, nothing left over."""
    de, other = _flat(_lang("de")), _flat(_lang(code))
    assert not (de - other), f"{code}.json is missing: {sorted(de - other)[:20]}"
    assert not (other - de), f"{code}.json has too much: {sorted(other - de)[:20]}"


def test_every_sentence_the_console_asks_for_exists():
    """A key without a sentence shows up raw on the screen."""
    have = _flat(_lang("de"))
    used = _used_keys(_sources())
    missing = sorted(k for k in used if k not in have and f"{k}_one" not in have)
    assert used, "no keys found — is the pattern still right?"
    assert not missing, f"asked for but not written: {missing}"


def test_every_server_error_code_has_a_sentence():
    sentences = _lang("de")["errors"]
    codes: set[str] = set()
    for f in (ROOT / "cinelounge").rglob("*.py"):
        text = f.read_text(encoding="utf-8")
        codes |= set(re.findall(r'Error\(\s*"([a-z_]+\.[a-z_]+)"', text))
        codes |= {m for m in re.findall(r'^[A-Z_]+: Final = "([a-z_]+\.[a-z_]+)"', text, re.M)}
    codes = {c for c in codes if not c.startswith("event.")}
    assert codes
    missing = sorted(c for c in codes if c not in sentences)
    assert not missing, f"without a sentence in de.json: {missing}"


def test_the_console_own_error_codes_have_a_sentence():
    """`api.ts` raises a few codes itself (no answer, broken answer, aborted)."""
    sentences = _lang("de")["errors"]
    api = (APP / "api.ts").read_text(encoding="utf-8")
    own = set(re.findall(r'ServerError\("([a-z]+\.[a-z_]+)"', api)) | set(
        re.findall(r'"(input\.[a-z_]+|server\.[a-z_]+)"', api)
    )
    assert own
    assert not sorted(c for c in own if c not in sentences)


def test_every_event_code_has_a_sentence():
    sentences = _lang("de")["events"]
    codes: set[str] = set()
    for f in (ROOT / "cinelounge").rglob("*.py"):
        codes |= set(re.findall(r'"event\.([a-z_]+)"', f.read_text(encoding="utf-8")))
    # One sentence per outcome for these two (`variant()` in i18n.ts).
    variants = {
        "portal_switched": ("portal_switched_on", "portal_switched_off"),
        "access_changed": ("access_granted", "access_revoked"),
    }
    missing = sorted(
        c
        for c in codes
        if c not in sentences and not all(v in sentences for v in variants.get(c, ("-",)))
    )
    assert not missing, f"events without a sentence: {missing}"


def test_every_call_of_the_console_hits_a_route(monkeypatch, tmp_path):
    """The old `test_console_contract`, for the new console: a path the console
    calls that the server does not have is a button that does nothing.

    The core's console calls only the core's routes — with or without an
    extension loaded, so the same test holds in both runs."""
    monkeypatch.setenv("CL_DATA", str(tmp_path))
    patterns = _route_patterns()
    calls = _calls(_sources())
    assert len(calls) > 40, calls
    unknown = sorted(c for c in calls if not any(p.match(c) for p in patterns))
    assert not unknown, f"the console calls routes that do not exist: {unknown}"


def test_the_core_reaches_an_extension_only_through_its_alias():
    """`cl-extension` is the one door (`vite.config.ts`, `tsconfig.json`):
    no core file imports from `extension/local`, and without the folder the build
    takes `none.ts`, which adds nothing."""
    core = [p for p in APP.rglob("*.ts*") if LOCAL not in p.parents]
    imports = re.compile(r"""(?:from|import)\s*\(?\s*["'][^"']*/local(?:/[^"']*)?["']""")
    named = sorted(str(p.relative_to(APP)) for p in core if imports.search(p.read_text("utf-8")))
    assert not named, named
    vite = (APP.parent / "vite.config.ts").read_text(encoding="utf-8")
    assert '"src/extension/local/index.ts"' in vite and '"src/extension/none.ts"' in vite
    tsconfig = json.loads((APP.parent / "tsconfig.json").read_text(encoding="utf-8"))
    assert tsconfig["compilerOptions"]["paths"]["cl-extension"] == ["./src/extension/none.ts"]
    none = (APP / "extension" / "none.ts").read_text(encoding="utf-8")
    assert "const extension: ConsoleExtension = {};" in none
    # Without a trailing slash: in development `local` is a symlink, and a
    # `dir/` rule never matches one (Git sees a symlink as a file).
    ignored = (APP.parent / ".gitignore").read_text(encoding="utf-8").splitlines()
    assert "src/extension/local" in ignored


def test_every_slot_a_page_renders_is_declared():
    """A `<Slot name="…">` without a declared name would render nothing, ever."""
    types = (APP / "extension" / "types.ts").read_text(encoding="utf-8")
    block = types.split("export type SlotProps = {", 1)[1].split("\n};", 1)[0]
    declared = set(re.findall(r'^\s*"?([a-z.]+)"?: \{', block, re.M))
    rendered = set(re.findall(r'<Slot name="([a-z.]+)"', _sources()))
    assert rendered and rendered <= declared, rendered - declared


def test_the_page_is_asked_for_every_time_and_assets_are_kept(monkeypatch, tmp_path):
    """`index.html` names the current asset files, so it must never come out of
    a cache; the assets carry a hash in their name and may stay for good."""
    console = tmp_path / "console"
    (console / "assets").mkdir(parents=True)
    (console / "index.html").write_text(
        '<script src="/assets/index-abc.js"></script>', encoding="utf-8"
    )
    (console / "assets" / "index-abc.js").write_text("1", encoding="utf-8")
    monkeypatch.setenv("CL_DATA", str(tmp_path))
    import importlib

    from fastapi.testclient import TestClient

    from cinelounge.web import main

    importlib.reload(main)
    monkeypatch.setattr(main, "CONSOLE", console)
    from fastapi.staticfiles import StaticFiles  # noqa: F401  (mount below)

    main.app.mount("/assets-test", main.Immutable(directory=console / "assets"), name="assets-test")
    client = TestClient(main.app)
    a = client.get("/")
    assert a.status_code == 200 and "index-abc.js" in a.text
    assert "no-cache" in a.headers["cache-control"]
    b = client.get("/assets-test/index-abc.js")
    assert b.status_code == 200 and "immutable" in b.headers["cache-control"]


def test_the_nightly_strip_is_as_long_as_the_console_draws():
    """The server keeps 14 nights; the console's `strip()` draws 14 by default."""
    from cinelounge.household.nights import NIGHTS

    model = (APP / "model.ts").read_text(encoding="utf-8")
    assert re.search(r"export function strip\([^)]*len = (\d+)", model).group(1) == str(NIGHTS)


def test_the_first_run_form_calls_the_route():
    gate = (APP / "Gate.tsx").read_text(encoding="utf-8")
    assert 'post("/setup"' in gate and 'post("/login"' in gate
    assert all(f'id="{i}"' in gate for i in ("su-code", "su-name", "su-pin"))


# ── Server additions made for the console ────────────────────────────────────


@pytest.fixture
def house(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient

    from cinelounge.web.access import Services

    folder = tmp_path / "portals" / "ard"
    folder.mkdir(parents=True)
    (folder / "portal.yml").write_text(
        "api: 1\nid: ard\nname: ARD\nkind: native\nenabled: true\n", encoding="utf-8"
    )
    (folder / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    monkeypatch.setenv("CL_DATA", str(tmp_path))
    import importlib

    from cinelounge.web import main

    importlib.reload(main)
    main.app.state.services = Services.from_path(tmp_path)
    d = main.app.state.services
    d.people.create("Max", "admin", "1234")
    d.people.create("Eli", "adult", "5555")
    d.people.create("Sina", "child", None)
    o = d.devices.request_code("Max", "phone", "192.0.2.5")
    return TestClient(main.app), {"X-CL-Device": d.devices.redeem(o.token, user_id="max")}, d


def test_members_say_role_console_pin_and_mark(house):
    client, head, _ = house
    people = {p["id"]: p for p in client.get("/household/members", headers=head).json()["people"]}
    assert people["max"]["console"] and people["max"]["has_pin"]
    assert people["sina"]["role_id"] == "child" and not people["sina"]["has_pin"]
    assert not people["sina"]["has_mark"]


def test_devices_say_when_and_how_they_came(house):
    client, head, _ = house
    dev = client.get("/household/devices", headers=head).json()["devices"][0]
    assert dev["paired"] > 0 and dev["via_mark"] is False


def test_sign_in_list_marks_console_holders(house):
    client, _, _ = house
    who = {p["id"]: p for p in client.get("/login/who").json()["people"]}
    assert who["max"]["console"] is True and who["eli"]["console"] is False
    assert "sina" not in who, "children never appear at the console's door"


def test_pin_change_checks_my_pin_when_sent(house):
    client, head, d = house
    a = client.post(
        "/household/people/eli/pin", json={"pin": "7777", "my_pin": "0000"}, headers=head
    )
    assert a.status_code == 401
    a = client.post(
        "/household/people/eli/pin", json={"pin": "7777", "my_pin": "1234"}, headers=head
    )
    assert a.status_code == 200
    assert d.people.sign_in("eli", "7777")


def test_nights_carry_failures_and_one_portal_can_be_checked(house, monkeypatch):
    client, head, d = house
    from cinelounge.household.nights import tonight

    d.nights.record("ard", False, step="play", reason="HTTP 403")
    n = client.get("/household/nights", headers=head).json()
    assert n["failures"]["ard"][0] == {"night": tonight(), "step": "play", "reason": "HTTP 403"}

    from cinelounge.web import nightwatch

    seen = []
    monkeypatch.setattr(
        nightwatch.nightly,
        "check",
        lambda m: seen.append(m.id)
        or type("R", (), {"ok": True, "step": "", "reason": "", "ms": 1})(),
    )
    a = client.post("/household/nights/run", json={"portal": "ard"}, headers=head)
    assert a.status_code == 200 and seen == ["ard"]
    assert (
        client.post("/household/nights/run", json={"portal": "nope"}, headers=head).status_code
        == 404
    )


def test_telegram_preview_uses_the_server_texts(house):
    client, head, _ = house
    m = client.get("/household/telegram/preview", headers=head).json()["messages"]
    assert set(m) == {"join_requested", "portal_failing", "exit_down"}
    assert "Selin" in m["join_requested"] and "ARD" in m["portal_failing"]
