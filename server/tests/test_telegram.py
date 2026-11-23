"""Telegram notifications and the exit watch (09.11.2026).

The Bot API is replaced by a fake that answers like the real one. Pinned down:
the whole flow from token to test message, the two "this bot is taken" cases,
that the token never comes back out, that only a chat that wrote /start can be
chosen, that the three events arrive in the household's language — and nothing
else does.
"""

from __future__ import annotations

import json
import time

import pytest
from fastapi.testclient import TestClient

from cinelounge.web import exitwatch, telegram
from cinelounge.web.access import Services

TOKEN = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"


class FakeBot:
    def __init__(self) -> None:
        self.sent: list[dict] = []
        self.updates: list[dict] = []
        self.webhook = ""
        self.other_reader = False
        self.calls: list[str] = []

    def __call__(self, url: str, params: dict, timeout: float) -> dict:
        token, method = url.split("/bot", 1)[1].split("/", 1)
        self.calls.append(method)
        if token != TOKEN:
            return {"ok": False, "error_code": 401, "description": "Unauthorized"}
        if method == "getMe":
            return {"ok": True, "result": {"username": "cl_home_bot", "first_name": "CineLounge"}}
        if method == "getWebhookInfo":
            return {"ok": True, "result": {"url": self.webhook}}
        if method == "getUpdates":
            if self.other_reader:
                return {
                    "ok": False,
                    "error_code": 409,
                    "description": "Conflict: terminated by other getUpdates request",
                }
            offset = params.get("offset")
            if offset:
                self.updates = [u for u in self.updates if u["update_id"] >= offset]
                return {"ok": True, "result": []}
            return {"ok": True, "result": list(self.updates)}
        if method == "sendMessage":
            self.sent.append(params)
            return {"ok": True, "result": {}}
        return {"ok": False, "error_code": 400, "description": "unknown method"}

    def start_from(self, chat_id: int, first_name: str, age_s: float = 5) -> None:
        self.updates.append(
            {
                "update_id": len(self.updates) + 100,
                "message": {
                    "text": "/start",
                    "date": int(time.time() - age_s),
                    "chat": {"id": chat_id, "type": "private", "first_name": first_name},
                },
            }
        )


@pytest.fixture
def house(tmp_path, monkeypatch):
    folder = tmp_path / "portals" / "ahorn"
    folder.mkdir(parents=True)
    (folder / "portal.yml").write_text(
        "api: 1\nid: ahorn\nname: {de: Ahorn Mediathek, en: Ahorn Media Library}\n"
        "kind: native\nenabled: true\n",
        encoding="utf-8",
    )
    (folder / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    monkeypatch.setenv("CL_DATA", str(tmp_path))
    import importlib

    from cinelounge.web import main

    importlib.reload(main)
    main.app.state.services = Services.from_path(tmp_path)
    d = main.app.state.services
    d.people.create("Max", "admin", "1234")
    d.people.create("Sina", "child", None)
    heads = {}
    for who in ("max", "sina"):
        o = d.devices.request_code(who, "phone", "192.0.2.5")
        heads[who] = {"X-CL-Device": d.devices.redeem(o.token, user_id=who)}
    d.store.write("haus.name", "Livingroom")
    bot = FakeBot()
    monkeypatch.setattr(telegram, "transport", bot)
    monkeypatch.setattr(telegram.threading, "Thread", _Inline)
    telegram.install(d)
    return TestClient(main.app), heads["max"], heads["sina"], d, bot


class _Inline:
    """Runs the "background" send at once, so a test can look at it."""

    def __init__(self, target, args=(), **_kw) -> None:
        self.target, self.args = target, args

    def start(self) -> None:
        self.target(*self.args)


def _connect(client, head, bot) -> None:
    assert (
        client.post("/household/telegram/check", json={"token": TOKEN}, headers=head).status_code
        == 200
    )
    bot.start_from(4711, "Max")
    cands = client.post("/household/telegram/wait", headers=head).json()["candidates"]
    assert (
        client.post(
            "/household/telegram/chat", json={"chat": cands[0]["id"]}, headers=head
        ).status_code
        == 200
    )


def test_the_whole_flow(house):
    client, head, _, _, bot = house
    a = client.post(
        "/household/telegram/check", json={"token": f"  {TOKEN} ", "language": "en"}, headers=head
    )
    assert a.status_code == 200, a.text
    state = a.json()
    assert state["bot"] == {"username": "cl_home_bot", "name": "CineLounge"}
    assert state["token_set"] and not state["connected"]
    assert TOKEN not in json.dumps(state), "the token never comes back out"

    assert client.post("/household/telegram/wait", headers=head).json()["candidates"] == []
    bot.start_from(4711, "Max")
    cands = client.post("/household/telegram/wait", headers=head).json()["candidates"]
    assert cands == [{"id": "4711", "title": "Max", "type": "private"}]
    assert bot.updates == [], "what was read is acknowledged"

    a = client.post("/household/telegram/chat", json={"chat": "4711"}, headers=head)
    assert a.status_code == 200 and a.json()["connected"]
    assert a.json()["chat"] == {"title": "Max"}
    assert a.json()["events"] == ["join_requested", "portal_failing", "exit_down"]
    assert bot.sent[-1]["chat_id"] == "4711" and bot.sent[-1]["text"].startswith(
        "Livingroom: Connected"
    )

    assert client.post("/household/telegram/test", headers=head).status_code == 200
    assert "Test message" in bot.sent[-1]["text"]
    assert TOKEN not in client.get("/household/telegram", headers=head).text


def test_a_taken_bot_is_said_plainly_and_nothing_is_stored(house):
    client, head, _, _, bot = house
    bot.webhook = "https://medien.example/hook"
    a = client.post("/household/telegram/check", json={"token": TOKEN}, headers=head)
    assert a.status_code == 409 and a.json()["error"]["code"] == "telegram.webhook_active"
    bot.webhook, bot.other_reader = "", True
    a = client.post("/household/telegram/check", json={"token": TOKEN}, headers=head)
    assert a.status_code == 409 and a.json()["error"]["code"] == "telegram.other_reader"
    assert not client.get("/household/telegram", headers=head).json()["token_set"]


def test_bad_tokens(house):
    client, head, *_ = house
    a = client.post("/household/telegram/check", json={"token": "hello"}, headers=head)
    assert a.json()["error"]["code"] == "telegram.bad_token_format"
    a = client.post(
        "/household/telegram/check", json={"token": "987654321:" + "x" * 35}, headers=head
    )
    assert a.status_code == 422 and a.json()["error"]["code"] == "telegram.bad_token"
    assert "987654321" not in a.text


def test_only_a_chat_that_wrote_start_can_be_chosen(house):
    client, head, _, _, bot = house
    client.post("/household/telegram/check", json={"token": TOKEN}, headers=head)
    bot.start_from(1, "Old", age_s=3600)  # too old to count
    assert client.post("/household/telegram/wait", headers=head).json()["candidates"] == []
    a = client.post("/household/telegram/chat", json={"chat": "999"}, headers=head)
    assert a.status_code == 404 and a.json()["error"]["code"] == "telegram.unknown_chat"


def test_the_three_events_arrive_and_nothing_else(house):
    client, head, _, d, bot = house
    _connect(client, head, bot)
    before = len(bot.sent)

    client.post(
        "/join",
        json={
            "name": "Kemal",
            "color": "#D6A13A",
            "device": "iPad",
            "kind": "ios",
            "want": ["portals"],
        },
    )
    d.events.record("event.portal_failing", {"portal": "ahorn", "step": "play", "why": "403"})
    d.events.record("event.exit_down", {"exit": "nord", "state": "stopped", "why": ""})
    d.events.record("event.portal_switched", {"portal": "ahorn", "on": False})  # not reported

    texts = [m["text"] for m in bot.sent[before:]]
    assert len(texts) == 3
    assert texts[0].startswith("Livingroom: Kemal möchte in den Haushalt – iPad, aus deinem Netz")
    assert "Ahorn Mediathek" in texts[1] and "Schritt: play" in texts[1]
    # The route's name, loud; the sentence around it may come from an extension.
    assert "NORD" in texts[2] and "stopped" in texts[2]


def test_switched_off_events_stay_quiet_and_failures_show(house):
    client, head, _, d, bot = house
    _connect(client, head, bot)
    a = client.put("/household/telegram/events", json={"events": ["exit_down"]}, headers=head)
    assert a.json()["events"] == ["exit_down"]
    assert (
        client.put(
            "/household/telegram/events", json={"events": ["gossip"]}, headers=head
        ).status_code
        == 422
    )

    before = len(bot.sent)
    d.events.record("event.join_requested", {"name": "X", "device": "Y", "from": "8.8.8.8"})
    assert len(bot.sent) == before

    # The bot was revoked at @BotFather: the send fails, the act does not, and
    # the settings say why.
    d.store.write(telegram.K_TOKEN, "123456789:" + "y" * 35)
    d.events.record("event.exit_down", {"exit": "sued", "state": "unreachable"})
    assert len(bot.sent) == before
    assert (
        client.get("/household/telegram", headers=head).json()["last_error"] == "telegram.bad_token"
    )


def test_disconnect_forgets_everything(house):
    client, head, _, d, bot = house
    _connect(client, head, bot)
    a = client.delete("/household/telegram", headers=head)
    assert a.status_code == 200
    assert a.json() == telegram.Telegram(d).state()
    assert not a.json()["connected"] and not a.json()["token_set"] and a.json()["bot"] is None
    assert all(not d.store.read(k, "") for k in telegram.ALL_KEYS)


def test_only_console_access_reaches_telegram(house):
    client, _, child, *_ = house
    for method, path in (("get", ""), ("post", "/test"), ("delete", "")):
        a = getattr(client, method)("/household/telegram" + path, headers=child)
        assert a.status_code == 403, path


def test_the_exit_watch_reports_once_after_two_misses():
    class Book:
        def __init__(self):
            self.lines = []

        def record(self, code, values=None, who=""):
            self.lines.append((code, values))

    book = Book()
    w = exitwatch.Watch(book)
    down = [{"id": "nord", "state": "stopped", "why": ""}, {"id": "sued", "state": "running"}]
    w.check(down)
    assert book.lines == [], "one miss is a hiccup"
    w.check(down)
    w.check(down)
    assert [c for c, _ in book.lines] == ["event.exit_down"], "one event per outage"
    w.check([{"id": "nord", "state": "running"}])
    assert [c for c, _ in book.lines] == ["event.exit_down", "event.exit_back"]
