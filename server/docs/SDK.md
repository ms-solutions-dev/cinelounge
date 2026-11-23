# Writing a portal

A **portal** is a source of things to watch. A Mediathek, a scraper, a folder
of files on a NAS — CineLounge does not care which, as long as it answers seven
questions.

This document is in English because you are probably not the person who wrote
the server. Everything else in this code base is German; this and
`portals/beispiel/` are the exception, and deliberately so.

**Read `portals/beispiel/portal.py` alongside this.** It is a complete, working
portal with no network of its own, and it is meant to be copied. This document
explains the reasons; that file shows the shape.

---

## The short version

A portal is a folder with two files:

```
myportal/
  portal.yml   the manifest — what it is and what it can do
  portal.py    a class named Portal with seven methods
```

Drop it into the server's `portals/` directory, restart, done. There is no
registration, no plugin API to call, no base class to inherit from. The server
reads the manifest, forks a child process, imports your file there, and calls
your class.

Portals are the common way to add content. Extending the server itself — new
portal kinds, manifest fields, routes — is a separate, smaller interface,
described in `docs/EXTENSIONS.md`. You do not need it to write a portal.

---

## The contract

Seven methods. The full definitions are in `cinelounge/core/contract.py`; this
is what each one is *for*.

| Method | Gives back | When it runs |
|---|---|---|
| `menu()` | `list[Entry]` | the entry screen, once |
| `listing(entry, next_page, user_input)` | `Page` | somebody opened a row |
| `children(item)` | `list[Item]` | somebody opened a series or folder |
| `sources(item)` | `list[Source]` | somebody pressed play |
| `resolve(source)` | `Stream` | immediately after, per source |
| `search(text)` | `list[Item]` | somebody typed something |
| `series(address)` | `str \| None` | resolving a per-series preference |

Plus three attributes:

```python
class Portal:
    id = "myportal"  # must equal `id:` in portal.yml
    name = "My Portal"
    capabilities = {"search"}  # must equal `capabilities:` in portal.yml
```

### Reading your settings: `configure()`

If your `portal.yml` declares `settings:`, add one more method. The runner
calls it once per child process, before the first question:

```python
def configure(self, settings: dict[str, str]) -> None:
    self._key = settings.get("api.key", "")
```

The values arrive flat — `{"api.key": "…", "quality.max": "1080"}` — with the
operator's entries already merged over your defaults. A key the operator never
filled in carries whatever you put in `value:`; one you left empty is `""`.

It is optional. A portal without settings does not need it.

**It did not exist until 11 September 2026**, and that was a gap with a
warning sign on it: the manifest reader parsed `settings:`, the console showed
them on the portal's page, the household's values were merged over the
defaults — and then `_portal_bauen()` called `module.Portal()` with no
arguments. Anyone following this document built a setting that never
arrived. If you are reading an older copy of this file, that is why.

---

**The server does not reconcile those two places for you.** It reads the
manifest for the console and calls the class for data. Claim `search` in one
and not the other and your portal is simply never asked, with nothing anywhere
saying why. `tests/test_beispielportal.py` checks exactly this for the example,
and your own tests should too.

### Why `sources()` and `resolve()` are separate

Because sources die. Splitting them lets the server walk a list: the first
source refuses, try the second, without asking the viewer anything. One
combined method would mean one attempt, and a dead source would look like a
dead portal.

If your source has no such thing — a Mediathek hands you the file address
directly — return one `Source` per quality step and be done. The shape costs
you four lines and buys the server its retry loop.

### Why `series()` exists

A viewer sets "German audio" on a series, once. To honour that while playing
*episode 7*, something has to turn the episode's address back into its series.
Only you can do that: only you know how your addresses are built.

No series? Return `None`. Then there is nothing to steer centrally either, and
the server stops asking.

---

## Three rules that bite

### 1. Never raise a sentence

```python
raise RuntimeError("no host worked")  # wrong
raise f.Error("stream.no_host", {"tried": 4})  # right
```

The household may be running the app in Turkish. A raised string reaches a
television verbatim. `cinelounge.core.errors.Error` takes a code and a dict of
values; the app looks up the sentence.

Pick a code with a prefix nobody else uses — `myportal.rate_limited` beats
`error`. If it has no translation yet, the app shows the code, which is ugly
and true, and gives whoever debugs it something to search for.

### 2. `next_page` is opaque

Whatever you put in `Page.next_page` comes back to `listing()` unchanged. The
server never parses it, never increments it, never validates it. Page number,
cursor, base64 blob, the whole upstream URL — all fine.

Which also means: **you** have to survive getting one back that you did not
produce. Somebody will eventually call your endpoint by hand.

### 3. An empty level is not an error

A folder with nothing in it is normal. A page past the last one is normal. A
category that emptied out overnight is normal.

```python
return Page(items=[], note="Nothing here right now.")
```

Raising there puts a red error on a television for something that is not one.
This was a real bug in an earlier version: every empty folder produced
`RuntimeError: the portal returned nothing`, at a dozen different places.

An actual crash still raises. Only "nothing there" means nothing there.

---

## What your code runs inside

Your portal runs in a **forked child process**, not in the API process. That is
not a detail — it is why fetching a foreign portal off the internet is a
defensible thing to do at all. The process that knows the household, the PINs
and the device tokens never has your code in it.

The child gets limits:

| | Default | Set by |
|---|---|---|
| Memory (`RLIMIT_AS`) | 256 MB | `portalworks/runner/fork.py` |
| CPU seconds | 25 | same |
| Wall clock | 20 s | same |
| Core dumps | none | same |

Consequences worth planning for:

- **Nothing persists between calls.** Module-level caches are per-call. If you
  need a token that survives, fetch it each time or accept that you will.
- **Your return value is serialised to JSON** through a pipe. Dataclasses from
  the contract work. A `datetime`, a `set`, a custom object does not — and it
  fails in the child, where it is harder to see. The example portal's
  `test_der_laeufer_ruft_die_vorlage_wirklich_auf` exists to catch this class
  of mistake, because a direct call never will.
- **20 seconds is the whole call**, not per request. Three sequential fetches
  at 8 seconds each is a timeout, not a slow response.
- `fork` is POSIX-only. On Windows the server starts but no portal runs. Test
  where it runs.

---

## The manifest

Full annotated example: `portals/beispiel/portal.yml`. The rules:

**Unknown keys are an error.** Not a warning, not ignored — the portal does not
load and the console says which key. This applies inside `settings` and
`limits` too. A typo in `required:` would otherwise do nothing at all while
changing everything. (An installed extension may register further top-level
keys; see `docs/EXTENSIONS.md`.)

**`api: 1`** is mandatory and must be a whole number. `api: true` and `api: 1.9`
are refused, which sounds pedantic until you notice Python thinks both are `1`.

**`en` is mandatory in `name`.** The fallback chain is: viewer's language → `en`
→ whatever is present. Without `en`, a Turkish household gets a German name
because that happened to be first in the file, and nobody decided that.

```yaml
name:
  en: My Portal      # required
  de: Mein Portal    # optional
```

A bare string counts as `en`, which is why `name: My Portal` is legal.

**Language keys are validated.** `DE:`, `deutsch:` and a slipped `dee:` all
produce a field nobody ever sees, because the lookup does not search for them.
Text nobody sees is worse than a load error.

**Capabilities are a closed set:**

`search` · `seasons` · `languages` · `resolver` · `login` · `own_images` ·
`subtitles` · `paging`

Declare what you implement. An undeclared capability that works is invisible; a
declared one that does not is a bug report from a stranger.

**Limits are a closed set:** `drm_partial` · `login_required` · `region_locked`
— the last may carry a country code (`region_locked: de`).

---

## Testing it

Copy the example's test file and change the names. The parts worth keeping:

- **Load it the way the runner does**, via `spec_from_file_location`, not
  `import portals.myportal.portal`. The second tests a code path that does not
  exist in production.
- **Read the manifest with the real reader**, `portalworks.manifest.read()`.
  It is the same function the service runs, and it never raises — it returns a
  manifest with `broken_reason` set. Assert `is_ready`.
- **Assert the manifest and the class agree** on `id` and `capabilities`.
- **Walk your paging to the end** with a loop bound. A `next_page` that never
  goes `None` is an infinite scroll on a television.
- **Go through the runner once**, guarded by `skipif(not hasattr(os, "fork"))`.
  That is the only test that proves your return values survive JSON.

To try it against a live server, put the folder in the server's portal
directory and restart. `GET /health` will list it under `portals`, and a broken
one shows up with its reason rather than vanishing.

---

## Publishing it

There is **no central index**, and that is the design, not a missing feature.
Whoever installs your portal decides to trust you, explicitly, by adding your
address.

### 1. Make an archive

A `.tar.gz` holding one directory with `portal.yml` in it. Both layouts work:

```sh
tar czf myportal-1.0.0.tar.gz myportal/          # directory inside
tar czf myportal-1.0.0.tar.gz -C myportal .      # contents at the root
```

No absolute paths, no `..`, **no symlinks** — the server unpacks entry by entry
and refuses all three. It does not call `extractall()`, for the reason every
Python security advisory has been giving for a decade.

Size limit: 50 MB. A portal is Python and a manifest.

### 2. Write an index

One JSON file, served over HTTP, at a stable address:

```json
{
  "api": 1,
  "name": "Jane's portals",
  "portals": [
    {
      "id": "myportal",
      "name": {"en": "My Portal", "de": "Mein Portal"},
      "description": {"en": "What it does, for someone deciding."},
      "version": "1.0.0",
      "url": "https://example.org/myportal-1.0.0.tar.gz",
      "sha256": "8f43...",
      "signature": "base64...",
      "kind": "native",
      "capabilities": ["search"],
      "adult": false,
      "homepage": "https://example.org/myportal"
    }
  ]
}
```

`id`, `version`, `url` and `sha256` are required; the rest is optional. Any
other key is an error, unless a loaded extension publishes a manifest field of
that name (`docs/EXTENSIONS.md`). An
entry the server cannot read is skipped with a complaint shown in the console,
and the other entries still load — one bad row does not take down your index.

`file:` URLs and ids containing path separators are refused.

The server **does not download anything while browsing**. It reads the index
and shows tiles; the archive is fetched when somebody installs. An index that
triggered a download per tile would be a very effective way to fill somebody's
disk.

### 3. Sign it, or don't

Unsigned is allowed. The console shows it grey, says "unsigned", and makes the
installer confirm. That is an honest state — nobody vouched for this — and not
a failure.

If you do sign, this is what is signed:

```python
import base64, hashlib, json
from nacl.signing import SigningKey

sk = SigningKey.generate()  # keep this; it is your identity
print(base64.b64encode(bytes(sk.verify_key)).decode())  # publish this

sha = hashlib.sha256(open("myportal-1.0.0.tar.gz", "rb").read()).hexdigest()

payload = json.dumps(
    {"id": "myportal", "version": "1.0.0", "sha256": sha},
    sort_keys=True,
    separators=(",", ":"),
).encode()

signature = base64.b64encode(sk.sign(payload).signature).decode()
```

Three fields, Ed25519, canonical JSON. Note what is **not** covered: name,
description, capabilities. Those are information and may change. What is
promised is "under this id and this version lies exactly this file".

`sort_keys` and `separators` are not style. Two sides serialising the same dict
differently get different signatures, and the failure then looks like a wrong
key rather than a formatting difference.

Publish the verify key somewhere people can check it against you — your site,
your repository, a post. Whoever wants your signature to count adds it as a
**trust anchor** in their console. Until somebody does, your signature reads as
`unsigned`: it is valid, but this household has not said it believes you.

A signature that is present and does **not** verify is a third state, `bad`.
There is no switch that installs those. It means either the file was swapped in
transit or the index is wrong, and both deserve a stop.

### 4. Updating

Publish a new version with a new `sha256` and a new signature. That is all.

Nothing auto-updates. There is no setting that turns it on. A service that
fetches foreign code while nobody is watching is a different kind of thing from
one you watch install, and this is the second kind. The console shows when a
newer version exists and a person presses the button.

The previous version is kept, once. A broken update is one click back.

---

## Things that will save you an afternoon

**Watch progress hangs off title and year, not your address.** `Item.key()`
builds `portal:normalised-title:year`. Change your URL scheme and nothing is
lost; change your portal `id` and every viewer's progress is orphaned.

**`image_wide` has three values.** `True`, `False`, and `None` for "cannot
tell". The app reads `== true` and `== false` separately so that a missing
answer never passes as a claim. Do not default it to `False` to be tidy.

**`count` in an `Entry` may be `None`.** That means unknown. It does not mean
zero, and a confident `0` next to a row that has items is worse than no number.

**`valid_until` in a `Stream` is not a cache hint.** Players fetch an address
twice — HEAD, then GET — and single-use tokens burn on the first. If you
do not know how long yours lives, `None` is the safe answer.

**Return `blocked=True` sources rather than hiding them.** A source that cannot
be used right now — it needs an account the household has not set up, say — is
something the viewer should see with a reason, not something that silently is
not there.

**Subtitle dicts use English keys**: `language`, `format`, `address`. An empty
list means "none for this title" and is an answer. A missing field is a
question.
