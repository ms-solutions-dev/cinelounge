"""What the loader has to refuse — and why the readiness checks belong with it.

**The yardstick, 10.09.2026.** `/health` reported `ready: 8, broken: []` while
most portals could not have played a single item. The loader checked every
key, every capability, every limit — but not whether the portal could work
with what it was given. A manifest that cannot work must not be called
`ready`.

The fields and checks of extensions are tested with the extension that brings
them; here stand the core's own.
"""

from __future__ import annotations

from cinelounge.portalworks import extension, manifest


def _schreibe(folder, body: str):
    folder.mkdir(parents=True, exist_ok=True)
    file = folder / "portal.yml"
    open(file, "w", encoding="utf-8").write(body)
    return file


def _nativ(folder, body: str):
    """A native portal: the manifest plus an empty `portal.py`."""
    file = _schreibe(folder, body)
    (folder / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    return file


PFLICHT = (
    "api: 1\nid: fichte\nname: Fichte\nkind: native\nenabled: true\n"
    "settings:\n  - key: api.key\n    value: ''\n    required: true\n"
)


def test_ohne_zusatzfelder_wird_nichts_behauptet(tmp_path):
    """A native portal with the core keys only is ready, and `extras` holds
    exactly what the loaded extensions registered — nothing without them."""
    file = _nativ(
        tmp_path / "zinne", "api: 1\nid: zinne\nname: Zinne\nkind: native\nenabled: true\n"
    )
    m = manifest.read(file)
    assert m.is_ready, m.broken_reason
    assert set(m.extras) == {s.key for s in extension.FIELDS}


def test_eine_pflichteinstellung_ohne_wert_macht_das_portal_kaputt(tmp_path):
    """`stream.no_host` was a lie — every host answered flawlessly.

    A portal that needs a key for every item it plays cannot play one without
    it; what the server said was "no host reachable". The objection "but paging
    works" is exactly the trap from `INHALTE.md`: a portal that pages but does
    not play is worse than one that is missing.
    """
    m = manifest.read(_nativ(tmp_path / "fichte", PFLICHT))
    assert not m.is_ready
    assert "api.key" in (m.broken_reason or "")


def test_ein_hinterlegter_wert_macht_das_portal_wieder_heil(tmp_path):
    """**The manifest belongs to the author, the value to the operator.**

    The first attempt wrote the key back into the `portal.yml`. Two reasons why
    that is wrong: `yaml.safe_dump` ate the file's comment header, and with E4
    the portal folder is pinned by `sha256` — a value in it does not survive
    the next version.
    """
    file = _nativ(tmp_path / "fichte", PFLICHT)
    m = manifest.read(file)
    assert not m.is_ready

    manifest.overlay(m, {"api.key": "geheim"})
    assert m.is_ready, m.broken_reason
    assert [e["value"] for e in m.settings if e["key"] == "api.key"] == ["geheim"]

    # And away again: the state has to go in both directions.
    m2 = manifest.read(file)
    manifest.overlay(m2, {"api.key": ""})
    assert not m2.is_ready


def test_ein_hinterlegter_wert_heilt_keinen_anderen_defekt(tmp_path):
    """A defect from reading stays, even when a setting is added."""
    file = _schreibe(tmp_path / "fichte", PFLICHT)  # no portal.py
    m = manifest.read(file)
    manifest.overlay(m, {"api.key": "geheim"})
    assert not m.is_ready
    assert "without portal.py" in (m.broken_reason or "")


def test_der_haushalt_haelt_portalwerte_getrennt(tmp_path):
    """Values lie under `portal.<id>.<key>` and do not disturb each other."""
    from cinelounge.household.store import Store

    store = Store(tmp_path / "h.sqlite")
    store.set_portal_setting("fichte", "api.key", "eins")
    store.set_portal_setting("birke", "api.key", "zwei")
    assert store.portal_settings("fichte") == {"api.key": "eins"}
    assert store.portal_settings("birke") == {"api.key": "zwei"}

    # An empty value means take away, not "stored as empty".
    store.set_portal_setting("fichte", "api.key", "")
    assert store.portal_settings("fichte") == {}
    assert store.portal_settings("birke") == {"api.key": "zwei"}


# ── Manifest v1: strict instead of silent (B4) ──────────────────────────────
#
# **Why all of this came at once.** Up to here the loader checks the top level
# of the manifest and lets everything below through. That does not show as
# long as the manifests come from one migration script — and it shows exactly
# when they no longer do. With A2 the app builds on these fields; from then on
# every change is a migration across two repos.
#
# The yardstick is not "strict" but: what this server does not fully
# understand is called `broken` and not `ready`.

EIGEN = "api: 1\nid: p\nname: Portal\nkind: native\n"


def _eigen(tmp_path, dazu: str = ""):
    """A native portal — the shortest way to a valid manifest."""
    (tmp_path / "p").mkdir(parents=True, exist_ok=True)
    (tmp_path / "p" / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    return manifest.read(_schreibe(tmp_path / "p", EIGEN + dazu))


def test_der_kuerzeste_gueltige_fall_bleibt_gueltig(tmp_path):
    """The cross-check first — otherwise the rest only checks that everything aborts."""
    m = _eigen(tmp_path)
    assert m.is_ready, m.broken_reason


# ── settings ────────────────────────────────────────────────────────────────


def test_ein_unbekannter_schluessel_in_settings_bricht_ab(tmp_path):
    """**The actual hole.** `requiered` is no `required`.

    A typo there does nothing and still changes everything: a required field
    becomes a suggestion, the portal is called `ready` and says
    `stream.no_host` at playback. The same half hour in the wrong direction as
    on 10.09.2026, only with a different trigger.
    """
    m = _eigen(tmp_path, "settings:\n  - key: a\n    value: ''\n    requiered: true\n")
    assert not m.is_ready
    assert "requiered" in (m.broken_reason or "")
    assert "'a'" in (m.broken_reason or ""), "the reason has to say which setting"


def test_dieselbe_einstellung_zweimal_bricht_ab(tmp_path):
    """Two entries with the same name would be two truths.

    `overlay()` writes into **every** matching entry, and a portal that gets
    its settings as a mapping keeps the last. Which one holds then depends
    on the caller — and that is no longer a setting but a die.
    """
    m = _eigen(tmp_path, "settings:\n  - key: a\n    value: '1'\n  - key: a\n    value: '2'\n")
    assert not m.is_ready
    assert "twice" in (m.broken_reason or "")


def test_eine_einstellung_ohne_key_bricht_ab(tmp_path):
    m = _eigen(tmp_path, "settings:\n  - value: '1'\n")
    assert not m.is_ready
    assert "without a key" in (m.broken_reason or "")


def test_required_ist_ja_oder_nein(tmp_path):
    """`required: "false"` is the string `false` — and that one is truthy."""
    m = _eigen(tmp_path, "settings:\n  - key: a\n    value: ''\n    required: vielleicht\n")
    assert not m.is_ready
    assert "yes or no" in (m.broken_reason or "")


def test_settings_muss_eine_liste_sein(tmp_path):
    m = _eigen(tmp_path, "settings:\n  a: 1\n")
    assert not m.is_ready
    assert "must be a list" in (m.broken_reason or "")


# ── Language fields ─────────────────────────────────────────────────────────


def test_eine_falsche_sprachkennung_bricht_ab(tmp_path):
    """A text under `dee:` never appears — `title()` does not look there."""
    (tmp_path / "q").mkdir(parents=True)
    (tmp_path / "q" / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    m = manifest.read(
        _schreibe(tmp_path / "q", "api: 1\nid: q\nkind: native\nname:\n  dee: Portal\n  en: P\n")
    )
    assert not m.is_ready
    assert "not a language code: dee" in (m.broken_reason or "")


def test_name_ohne_en_bricht_ab(tmp_path):
    """**Measured: seven of eight live portals failed here.**

    The migration hard-wrote `name: {de: …}`. Without `en` a Turkish viewer
    has nothing but the `id` in front of a German manifest — and the manifest
    is the one surface strangers touch. A fix-up script adds it afterwards.
    """
    (tmp_path / "q").mkdir(parents=True)
    (tmp_path / "q" / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    m = manifest.read(
        _schreibe(tmp_path / "q", "api: 1\nid: q\nkind: native\nname:\n  de: Portal\n")
    )
    assert not m.is_ready
    assert "no en" in (m.broken_reason or "")


def test_die_kurzform_zaehlt_als_rueckfallsprache(tmp_path):
    """Whoever writes only one name writes the one everybody is meant to read."""
    m = _eigen(tmp_path)
    assert m.name == {"en": "Portal"}
    assert m.title("tr") == "Portal", "the chain has to fall back over en"


def test_die_beschreibung_faellt_wie_der_name_zurueck(tmp_path):
    """`blurb()` did not exist — `as_json` gave the name translated and the
    description not at all. In the marketplace (B6) it is what somebody picks
    a foreign portal by.
    """
    m = _eigen(tmp_path, "description:\n  de: Deutsch\n  en: English\n")
    assert m.blurb("de") == "Deutsch"
    assert m.blurb("tr") == "English", "fall back over en"
    assert m.as_json("tr")["description"] == "English"


def test_eine_kaputte_beschreibung_faellt_nicht_mehr_auf_den_boden(tmp_path):
    """Before, the complaint landed in `_` and `description: 42` quietly became
    "no description"."""
    m = _eigen(tmp_path, "description: 42\n")
    assert not m.is_ready
    assert "description" in (m.broken_reason or "")


# ── Lists, numbers, network ─────────────────────────────────────────────────


def test_eine_faehigkeit_als_text_wird_nicht_in_buchstaben_zerlegt(tmp_path):
    """`capabilities: search` looked right and reported
    `unknown capability: a, c, e, h, r, s`. With a message like that one looks
    for the fault in oneself.
    """
    m = _eigen(tmp_path, "capabilities: search\n")
    assert not m.is_ready
    assert "must be a list" in (m.broken_reason or "")
    assert "capabilities" in (m.broken_reason or "")


def test_eine_api_die_keine_zahl_ist_bricht_nicht_den_durchlauf(tmp_path):
    """`read()` promises never to raise — `int("v1")` did anyway.

    A single broken manifest would thereby have aborted the whole pass instead
    of only itself.
    """
    (tmp_path / "q").mkdir(parents=True)
    m = manifest.read(_schreibe(tmp_path / "q", "api: v1\nid: q\nname: Q\nkind: native\n"))
    assert not m.is_ready
    assert "not a whole number" in (m.broken_reason or "")


def test_eine_api_die_fast_eine_zahl_ist_zaehlt_nicht_als_eins(tmp_path):
    """`int()` is too good-natured: `int(True)` is 1, `int(1.9)` too.

    Both would have passed as version 1. A version number is a whole number —
    and in Python `bool` is one only by accident.
    """
    (tmp_path / "q").mkdir(parents=True)
    (tmp_path / "q" / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    for wert in ("true", "1.9"):
        m = manifest.read(_schreibe(tmp_path / "q", f"api: {wert}\nid: q\nname: Q\nkind: native\n"))
        assert not m.is_ready, wert
        assert "not a whole number" in (m.broken_reason or ""), wert


# ── Limits ──────────────────────────────────────────────────────────────────


def test_eine_geo_sperre_ohne_laender_sagt_nichts(tmp_path):
    """`INHALTE.md`: "A geo-blocked portal looks like a broken one."

    The app makes a sentence of it before somebody clicks four titles and
    experiences the same thing four times — for that it needs the countries,
    not only the word.
    """
    m = _eigen(tmp_path, "limits:\n  - region_locked\n")
    assert not m.is_ready
    assert "list the countries" in (m.broken_reason or "")


def test_eine_geo_sperre_mit_laendern_ist_in_ordnung(tmp_path):
    m = _eigen(tmp_path, "limits:\n  - region_locked: [fr, de]\n")
    assert m.is_ready, m.broken_reason
    assert m.limits == [{"region_locked": ["fr", "de"]}]


def test_eine_grenze_ohne_wert_nimmt_keinen(tmp_path):
    """`drm_partial: true` reads right and is still wrong — the value would be
    read nowhere."""
    m = _eigen(tmp_path, "limits:\n  - drm_partial: true\n")
    assert not m.is_ready
    assert "takes no value" in (m.broken_reason or "")


def test_ein_falscher_laendercode_in_der_geo_sperre_bricht_ab(tmp_path):
    m = _eigen(tmp_path, "limits:\n  - region_locked: [Frankreich]\n")
    assert not m.is_ready
    assert "not a country code" in (m.broken_reason or "")


def test_eine_grenze_ohne_wert_bleibt_erlaubt(tmp_path):
    """The short form is the normal case and must not be cleared away with it."""
    m = _eigen(tmp_path, "limits:\n  - drm_partial\n  - login_required\n")
    assert m.is_ready, m.broken_reason


# ── What the review of 11.09.2026 found ─────────────────────────────────────


def test_eine_unwahre_beschreibung_ist_trotzdem_eine_kaputte(tmp_path):
    """`or {}` ran before the type check and let every falsy value through.

    `description: 0`, `description: false` and `description: ''` all quietly
    became "no description" again — exactly what was meant to be abolished
    here.
    """
    for wert in ("0", "false", "''"):
        m = _eigen(tmp_path, f"description: {wert}\n")
        assert not m.is_ready, wert
        assert "description" in (m.broken_reason or ""), wert


def test_ein_leeres_description_heisst_wirklich_keine(tmp_path):
    """The cross-check: `description:` without a value is `None` in YAML.

    That is "not given" and the only falsy value that may pass — otherwise the
    check above would only be a shutdown.
    """
    m = _eigen(tmp_path, "description:\n")
    assert m.is_ready, m.broken_reason
    assert m.blurb() == ""


def test_ein_leeres_net_meldet_keinen_wert_den_niemand_getippt_hat(tmp_path):
    """An empty `net:` from an older manifest reads as what it always meant:
    the portal goes direct. It never names the author a value they did not
    write.
    """
    m = _eigen(tmp_path, "net:\n")
    assert m.is_ready, m.broken_reason
    assert m.exit_net == "direct"
