"""Telegram notifications (09.11.2026).

The flow the owner approved, as simple as it gets:

1. paste the bot token → **check** (`getMe`; a webhook or another program
   already reading the bot is detected here and said plainly);
2. write `/start` to the bot → **wait** (`getUpdates`, short-lived) shows who
   wrote;
3. **"that's me"** → the chat is stored and greeted;
4. choose the events, send a **test message**.

Nobody types a chat id. Several recipients: a Telegram group with the bot in it
— `/start` written in the group makes the group the recipient.

**One bot per CineLounge.** `getUpdates` hands every message to exactly one
reader; a bot shared with medien.example would steal its messages (Telegram
answers 409 to the second reader, which is what step 1 detects).

**The token is a secret.** It is stored in the household settings like other
keys, goes into backups like them, and never leaves through the API — the
state says `token_set`, nothing more. It never appears in an error either.

**Texts come from `web/messages/{lang}.json`**, in the language of whoever
connected the bot; they are not editable in the console.
"""

from __future__ import annotations

import ipaddress
import json
import re
import threading
import time
import urllib.error
import urllib.request
from functools import cache
from pathlib import Path
from typing import Annotated, Any, Final

from fastapi import APIRouter, Body, Request

from cinelounge.core import errors as f
from cinelounge.web import extension
from cinelounge.web.access import Admin, Services, services

API: Final = "https://api.telegram.org"

#: What can be reported, and the event in the book that triggers it.
EVENTS: Final = {
    "join_requested": "event.join_requested",
    "portal_failing": "event.portal_failing",
    "exit_down": "event.exit_down",
}
LANGUAGES: Final = ("de", "en", "tr")

#: Settings keys. Underscores, not dots: a dotted key reads like an error
#: code to the checks that keep codes and language files in step.
K_TOKEN: Final = "telegram_token"
K_BOT: Final = "telegram_bot"
K_CHAT: Final = "telegram_chat"
K_CHAT_TITLE: Final = "telegram_chat_title"
K_EVENTS: Final = "telegram_events"
K_LANGUAGE: Final = "telegram_language"
K_ERROR: Final = "telegram_last_error"
K_SEEN: Final = "telegram_seen"
ALL_KEYS: Final = (K_TOKEN, K_BOT, K_CHAT, K_CHAT_TITLE, K_EVENTS, K_LANGUAGE, K_ERROR, K_SEEN)

_TOKEN: Final = re.compile(r"^\d{5,12}:[A-Za-z0-9_-]{30,50}$")
#: How old a `/start` may be to count — and how long "that's me" stays possible.
FRESH_S: Final = 900.0
#: How long one wait for `/start` lasts at most (Telegram's long poll).
WAIT_S: Final = 20

MESSAGES: Final = Path(__file__).parent / "messages"


# ── Talking to Telegram ──────────────────────────────────────────────────────


def transport(url: str, params: dict[str, Any], timeout: float) -> dict[str, Any]:
    """One POST to the Bot API. Replaced in tests."""
    req = urllib.request.Request(
        url,
        data=json.dumps(params).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as answer:
        body = json.loads(answer.read().decode("utf-8", "replace"))
    return body if isinstance(body, dict) else {}


def _call(
    token: str, method: str, params: dict[str, Any] | None = None, timeout: float = 10.0
) -> Any:
    try:
        body = transport(f"{API}/bot{token}/{method}", params or {}, timeout)
    except urllib.error.HTTPError as err:
        # Telegram answers errors with a JSON body; that body says why.
        try:
            body = json.loads(err.read().decode("utf-8", "replace"))
        except (ValueError, OSError):
            body = {"ok": False, "error_code": err.code}
    except (urllib.error.URLError, OSError, ValueError):
        # Deliberately without the exception text: it would contain the URL,
        # and the URL contains the token.
        raise f.Error("telegram.unreachable", status=502) from None
    if body.get("ok"):
        return body.get("result")
    code, why = body.get("error_code"), str(body.get("description", ""))
    if code in (401, 404):
        raise f.Error("telegram.bad_token", status=422)
    if code == 409:
        name = "telegram.webhook_active" if "webhook" in why.lower() else "telegram.other_reader"
        raise f.Error(name, status=409)
    if code == 403:
        raise f.Error("telegram.blocked", status=409)
    raise f.Error("telegram.failed", {"why": why[:120]}, status=502)


# ── Texts ────────────────────────────────────────────────────────────────────


@cache
def _core_texts(language: str) -> dict[str, str]:
    path = MESSAGES / f"{language}.json"
    if not path.exists():
        path = MESSAGES / "en.json"
    return dict(json.loads(path.read_text(encoding="utf-8"))["telegram"])


def _texts(language: str) -> dict[str, str]:
    """The core's texts, with what extensions bring for this language over them
    (`ExtensionContext.event_texts`)."""
    if not (MESSAGES / f"{language}.json").exists():
        language = "en"
    return {**_core_texts(language), **extension.event_texts(language)}


class _Keep(dict[str, str]):
    """`format_map` that leaves an unknown placeholder standing instead of failing."""

    def __missing__(self, key: str) -> str:
        return "{" + key + "}"


# ── The feature ──────────────────────────────────────────────────────────────


class Telegram:
    """Telegram for one household. Cheap to build; holds no state of its own."""

    def __init__(self, d: Services) -> None:
        self.d = d
        self.store = d.store
        #: Tests set this so a message is sent before `record()` returns.
        self.synchronous = False

    # Reading

    def _get(self, key: str) -> str:
        return str(self.store.read(key, "") or "")

    def events(self) -> list[str]:
        return [e for e in self._get(K_EVENTS).split(",") if e in EVENTS]

    def language(self) -> str:
        lang = self._get(K_LANGUAGE)
        return lang if lang in LANGUAGES else "de"

    def connected(self) -> bool:
        return bool(self._get(K_TOKEN) and self._get(K_CHAT))

    def state(self) -> dict[str, Any]:
        bot = self._get(K_BOT)
        chat = self._get(K_CHAT)
        return {
            "connected": self.connected(),
            "token_set": bool(self._get(K_TOKEN)),
            "bot": json.loads(bot) if bot else None,
            "chat": {"title": self._get(K_CHAT_TITLE)} if chat else None,
            "events": self.events(),
            "available_events": list(EVENTS),
            "language": self.language(),
            "last_error": self._get(K_ERROR) or None,
        }

    # Step 1: check the token

    def check(self, token: str, language: str) -> dict[str, Any]:
        token = token.strip()
        if not _TOKEN.match(token):
            raise f.Error("telegram.bad_token_format", status=422)
        me = _call(token, "getMe")
        hook = _call(token, "getWebhookInfo") or {}
        if hook.get("url"):
            raise f.Error("telegram.webhook_active", status=409)
        # A peek without `offset` consumes nothing; a second reader answers 409.
        _call(token, "getUpdates", {"timeout": 0, "limit": 1})
        if token != self._get(K_TOKEN):
            for k in (K_CHAT, K_CHAT_TITLE, K_SEEN, K_ERROR):
                self.store.write(k, "")
        self.store.write(K_TOKEN, token)
        bot = {"username": me.get("username", ""), "name": me.get("first_name", "")}
        self.store.write(K_BOT, json.dumps(bot, ensure_ascii=False))
        self.store.write(K_LANGUAGE, language if language in LANGUAGES else "de")
        return self.state()

    # Step 2: wait for /start

    def wait_for_start(self, wait_s: int = WAIT_S) -> list[dict[str, Any]]:
        token = self._require_token()
        updates = (
            _call(
                token,
                "getUpdates",
                {"timeout": wait_s, "allowed_updates": ["message"]},
                timeout=wait_s + 10,
            )
            or []
        )
        now = time.time()
        seen: dict[str, dict[str, Any]] = self._seen()
        for u in updates:
            msg = u.get("message") or {}
            if not str(msg.get("text", "")).startswith("/start"):
                continue
            if now - float(msg.get("date", 0)) > FRESH_S:
                continue
            chat = msg.get("chat") or {}
            if "id" not in chat:
                continue
            title = (
                chat.get("title")
                or " ".join(x for x in (chat.get("first_name"), chat.get("last_name")) if x)
                or chat.get("username")
                or str(chat["id"])
            )
            seen[str(chat["id"])] = {"title": title, "type": chat.get("type", ""), "at": now}
        if updates:
            # Acknowledge what was read, so the next wait starts fresh.
            last = max(int(u.get("update_id", 0)) for u in updates)
            _call(token, "getUpdates", {"offset": last + 1, "timeout": 0})
        self.store.write(K_SEEN, json.dumps(seen, ensure_ascii=False))
        return [{"id": k, "title": v["title"], "type": v["type"]} for k, v in seen.items()]

    def _seen(self) -> dict[str, dict[str, Any]]:
        raw = self._get(K_SEEN)
        seen = json.loads(raw) if raw else {}
        now = time.time()
        return {k: v for k, v in seen.items() if now - float(v.get("at", 0)) <= FRESH_S}

    # Step 3: "that's me"

    def choose(self, chat_id: str) -> dict[str, Any]:
        token = self._require_token()
        seen = self._seen()
        if chat_id not in seen:
            # Only a chat that wrote /start just now — a typed-in id would let
            # the household report to anybody.
            raise f.Error("telegram.unknown_chat", status=404)
        self.store.write(K_CHAT, chat_id)
        self.store.write(K_CHAT_TITLE, str(seen[chat_id]["title"]))
        self.store.write(K_SEEN, "")
        if not self._get(K_EVENTS):
            self.store.write(K_EVENTS, ",".join(EVENTS))
        self._send(token, chat_id, self._render("connected", {}))
        return self.state()

    # Step 4: events and the test message

    def set_events(self, events: list[str]) -> dict[str, Any]:
        unknown = sorted(set(events) - set(EVENTS))
        if unknown:
            raise f.Error("telegram.unknown_event", {"events": unknown}, status=422)
        self.store.write(K_EVENTS, ",".join(e for e in EVENTS if e in events))
        return self.state()

    def test(self) -> dict[str, Any]:
        token, chat = self._require_token(), self._get(K_CHAT)
        if not chat:
            raise f.Error("telegram.not_connected", status=409)
        self._send(token, chat, self._render("test", {}))
        self.store.write(K_ERROR, "")
        return self.state()

    def disconnect(self) -> None:
        for k in ALL_KEYS:
            self.store.write(k, "")

    # Sending for events

    def on_event(self, code: str, values: dict[str, Any]) -> None:
        name = next((k for k, v in EVENTS.items() if v == code), None)
        if name is None or not self.connected() or name not in self.events():
            return
        text = self._render(name, values)
        token, chat = self._get(K_TOKEN), self._get(K_CHAT)
        if self.synchronous:
            self._send_quietly(token, chat, text)
        else:
            threading.Thread(
                target=self._send_quietly, args=(token, chat, text), name="telegram", daemon=True
            ).start()

    def _send_quietly(self, token: str, chat: str, text: str) -> None:
        """For events: never raises; the last failure is shown in the settings."""
        try:
            self._send(token, chat, text)
            self.store.write(K_ERROR, "")
        except f.Error as err:
            self.store.write(K_ERROR, err.code)
        except Exception:
            self.store.write(K_ERROR, "telegram.failed")

    def _send(self, token: str, chat: str, text: str) -> None:
        _call(
            token,
            "sendMessage",
            {"chat_id": chat, "text": text[:4000], "disable_web_page_preview": True},
        )

    def _render(self, name: str, values: dict[str, Any]) -> str:
        lang = self.language()
        texts = _texts(lang)
        v = _Keep({k: str(x) for k, x in values.items()})
        v["household"] = str(self.store.read("haus.name", "") or "CineLounge")
        if "portal" in values:
            m = self.d.registry.manifests.get(str(values["portal"]))
            v["portal"] = m.title(lang) if m else str(values["portal"])
        if "exit" in values:
            v["exit"] = str(values["exit"]).upper()
        v["where"] = texts[
            "where_outside" if _outside(str(values.get("from", ""))) else "where_home"
        ]
        return texts[name].format_map(v).strip()

    def _require_token(self) -> str:
        token = self._get(K_TOKEN)
        if not token:
            raise f.Error("telegram.not_connected", status=409)
        return token


def _outside(address: str) -> bool:
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    return not (ip.is_private or ip.is_loopback or ip.is_link_local)


def install(d: Services) -> None:
    """Hang Telegram on the household's event book."""
    d.events.listeners.append(lambda code, values: Telegram(d).on_event(code, values))


# ── Routes ───────────────────────────────────────────────────────────────────

router = APIRouter(prefix="/household/telegram")


@router.get("")
def read_state(request: Request, _: Admin) -> dict[str, Any]:
    return Telegram(services(request)).state()


#: Example values for the preview in the console — the real texts, filled.
EXAMPLES: Final = {
    "join_requested": {"name": "Selin", "device": "iPhone", "from": "192.0.2.54"},
    "portal_failing": {"portal": "ard", "step": "play", "why": "HTTP 403"},
    "exit_down": {"exit": "nord", "state": "unreachable"},
}


@router.get("/preview")
def preview(request: Request, _: Admin, language: str = "") -> dict[str, Any]:
    """The three messages as they will arrive, from `web/messages` — so the
    console never keeps a second copy of the texts."""
    tg = Telegram(services(request))
    if language in LANGUAGES:
        tg.language = lambda: language  # type: ignore[method-assign]
    examples = {**EXAMPLES, **extension.event_examples()}
    return {"messages": {k: tg._render(k, examples.get(k, v)) for k, v in EXAMPLES.items()}}


@router.post("/check")
def check_token(
    request: Request,
    _: Admin,
    token: Annotated[str, Body(embed=True)],
    language: Annotated[str, Body(embed=True)] = "de",
) -> dict[str, Any]:
    return Telegram(services(request)).check(token, language)


@router.post("/wait")
def wait_for_start(request: Request, _: Admin) -> dict[str, Any]:
    """Blocks up to `WAIT_S` seconds; the console calls it again while waiting."""
    return {"candidates": Telegram(services(request)).wait_for_start()}


@router.post("/chat")
def choose_chat(
    request: Request, person: Admin, chat: Annotated[str, Body(embed=True)]
) -> dict[str, Any]:
    d = services(request)
    state = Telegram(d).choose(chat)
    d.events.record("event.telegram_connected", {"chat": state["chat"]["title"]}, person.id)
    return state


@router.put("/events")
def choose_events(
    request: Request, _: Admin, events: Annotated[list[str], Body(embed=True)]
) -> dict[str, Any]:
    return Telegram(services(request)).set_events(events)


@router.post("/test")
def send_test(request: Request, _: Admin) -> dict[str, Any]:
    return Telegram(services(request)).test()


@router.delete("")
def disconnect(request: Request, person: Admin) -> dict[str, Any]:
    d = services(request)
    Telegram(d).disconnect()
    d.events.record("event.telegram_disconnected", {}, person.id)
    return Telegram(d).state()
