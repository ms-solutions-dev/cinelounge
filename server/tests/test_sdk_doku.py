"""`docs/SDK.md` against the code it describes.

**Why this file of all things is checked.** It is the only one somebody reads
who does not know the project — and the only one whose errors do not show,
because all of us here know how it really is. That is exactly how it stood in
`docs/PROMPT-APP.md`: `POST /redeem {"code": …}` where the server expects
`token`, `from_where` in the body where the field never existed, `page=`
instead of `next=`. Three claims that would have cost every app
implementation, and the file looked complete.

Only what can be held mechanically is checked: lists, numbers and names.
Whether a paragraph is right, a human still checks.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from cinelounge.market import install as market_install
from cinelounge.portalworks import manifest as manifest_lesen
from cinelounge.portalworks.runner import call as runner
from cinelounge.portalworks.runner import fork

DOKU = Path(__file__).resolve().parent.parent / "docs" / "SDK.md"


@pytest.fixture(scope="module")
def text() -> str:
    return DOKU.read_text(encoding="utf-8")


def test_die_doku_gibt_es(text):
    assert len(text) > 2000, "SDK docs under 2000 characters explain nothing"


def test_faehigkeiten_stimmen(text):
    """The list in the docs is the list in the manifest reader.

    An invented capability breaks the portal at load time — with a message
    pointing at the manifest and not at the docs that recommended it.
    """
    block = re.search(r"\*\*Capabilities are a closed set:\*\*\s*\n\s*\n(.+?)\n\s*\n", text, re.S)
    assert block, "the section on capabilities is missing or named differently"
    genannt = set(re.findall(r"`([a-z_]+)`", block.group(1)))
    assert genannt == manifest_lesen.CAPABILITIES, (
        "Doku: " + str(sorted(genannt)) + " / Code: " + str(sorted(manifest_lesen.CAPABILITIES))
    )


def test_limits_stimmen(text):
    block = re.search(r"\*\*Limits are a closed set:\*\*(.+?)\n\s*\n", text, re.S)
    assert block, "the section on limits is missing or named differently"
    genannt = set(re.findall(r"`([a-z_]+)`", block.group(1)))
    # `region_locked: de` stands beside it as an example and is no limit of its own.
    genannt -= {"de"}
    assert genannt == manifest_lesen.LIMITS, (
        "Doku: " + str(sorted(genannt)) + " / Code: " + str(sorted(manifest_lesen.LIMITS))
    )


def test_die_sieben_methoden_stehen_alle_drin(text):
    """Every method the runner calls is explained too.

    And none that does not exist: whoever finds `serie()` in the docs and
    implements it writes a method that is never called.
    """
    tabelle = re.search(r"\| Method \| Gives back \| When it runs \|(.+?)\n\n", text, re.S)
    assert tabelle, "the method table is missing"
    genannt = set(re.findall(r"\| `(\w+)\(", tabelle.group(1)))
    assert genannt == runner.METHODS, (
        "Doku: " + str(sorted(genannt)) + " / Laeufer: " + str(sorted(runner.METHODS))
    )


def test_die_grenzen_sind_die_echten(text):
    """256 MB, 25 s, 20 s — numbers somebody builds their code around.

    Docs promising 60 seconds where 20 hold produce portals that run in the
    workshop and abort on the television.
    """
    assert f"| {fork.MEMORY_MB} MB |" in text, f"memory limit is {fork.MEMORY_MB} MB"
    assert f"| {fork.CPU_S} |" in text, f"CPU limit is {fork.CPU_S} s"
    assert f"| {int(fork.DEADLINE_S)} s |" in text, f"deadline is {fork.DEADLINE_S} s"
    # And in the prose below the same number stands once more.
    assert f"**{int(fork.DEADLINE_S)} seconds is the whole call**" in text


def test_die_groessengrenze_stimmt(text):
    mb = market_install.MAX_BYTES // (1024 * 1024)
    assert f"Size limit: {mb} MB" in text, f"archive limit is {mb} MB"


def test_der_signaturkern_hat_genau_drei_felder(text):
    """The three fields in the example are the three from `signing_payload`.

    A fourth field in the example yields signatures that verify nowhere — and
    the fault looks like a wrong key.
    """
    from cinelounge.market import trust

    kern = trust.signing_payload({"id": "x", "version": "1", "sha256": "AB"})
    import json

    felder = set(json.loads(kern))

    block = re.search(r"payload = json\.dumps\((.+?)\)\.encode\(\)", text, re.S)
    assert block, "the signature example is missing"
    im_beispiel = set(re.findall(r'"(\w+)":', block.group(1)))
    assert im_beispiel == felder, (
        "Doku: " + str(sorted(im_beispiel)) + " / Code: " + str(sorted(felder))
    )
    # And the canonical form, without which two sides build different sums.
    assert "sort_keys=True" in block.group(1)
    assert 'separators=(",", ":")' in block.group(1)


def test_die_pflichtfelder_des_index_stimmen(text):
    """`id`, `version`, `url`, `sha256` — the same four as in the reader."""
    from cinelounge.market import index as index_lesen

    quelle = (Path(index_lesen.__file__)).read_text(encoding="utf-8")
    pflicht = re.search(r"for pflicht in \(([^)]+)\)", quelle)
    assert pflicht, "the required fields no longer stand where they stood"
    im_code = set(re.findall(r'"(\w+)"', pflicht.group(1)))

    satz = re.search(r"\n(`\w+`(?:, `\w+`)*(?: and `\w+`)?) are required", text)
    assert satz, "the sentence about required fields is missing"
    in_doku = set(re.findall(r"`(\w+)`", satz.group(1)))
    assert in_doku == im_code, "Doku: " + str(sorted(in_doku)) + " / Code: " + str(sorted(im_code))


def test_das_beispielportal_wird_genannt_und_gibt_es(text):
    """The docs point at the template. The template has to be there."""
    assert "portals/beispiel/portal.py" in text
    assert "portals/beispiel/portal.yml" in text
    wurzel = DOKU.parent.parent
    assert (wurzel / "portals" / "beispiel" / "portal.py").is_file()
    assert (wurzel / "portals" / "beispiel" / "portal.yml").is_file()
