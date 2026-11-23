import Foundation

/// Which of the two services is being talked to — **and in which words.**
///
/// **The finding (2026-09-12):** the CineLounge server replaces the portals bridge. It
/// answers the same questions, in the same form, but in a different language: the bridge
/// writes `portals`, `title`, `bild_breit`, the server `portals`, `title`, `image_wide`. The
/// shape of the responses has stayed the same character for character.
///
/// **That is why there is no second kind of response model here.** Two sets of DTOs for the
/// same shape would mean maintaining every future field twice — and they would drift apart as
/// soon as someone forgets once. Instead one language remains the inner one: the bridge's.
/// ``PortalDialect`` translates paths, query parts and response keys at exactly one place, and
/// for ``bridge`` every one of these translations is the identity.
///
/// **That is also the reason the bridge can stay.** The way back costs no second code model,
/// but an enumeration value — and which one applies is answered by the service itself via
/// ``ServerVersion``.
public enum PortalDialect: String, Sendable, CaseIterable {

    /// The old portals bridge on `…:8099`. Speaks German, knows no persons.
    case bridge = "bruecke"

    /// The CineLounge server on `…:8100`. Speaks English, knows persons and devices.
    case cinelounge

    // ── Wege ─────────────────────────────────────────────────────────────────

    /// The path under which this service carries the same thing.
    ///
    /// **Only the last segment** is translated: `p/zdf/list` has three parts, and the portal name
    /// in the middle is not a vocabulary word but a name.
    func route(_ inner: String) -> String {
        guard self == .cinelounge else { return inner }
        var split = inner.split(separator: "/", omittingEmptySubsequences: false)
        guard let last = split.last.map(String.init) else { return inner }
        split[split.count - 1] = Substring(Self.routes[last] ?? last)
        return split.joined(separator: "/")
    }

    private static let routes: [String: String] = [
        "portale": "portals",
        "liste": "list",
        "kinder": "children",
        "quellen": "sources",
        "suche": "search",
        "stand": "state",
        "weiterschauen": "resume",
        "favoriten": "favorites",
            // `menu` is `menu` for both; it is not listed here for completeness, because a line that
            // changes nothing is only an opportunity for error.
    ]

    // ── Frageteile ───────────────────────────────────────────────────────────

    /// The query parts of an address in the language of this service.
    ///
    /// **Unknown parts are dropped instead of slipping through.** `weiterleiten=false` is a
    /// question to the bridge — the server in principle does not redirect, and a part it does not
    /// know would be an error for it instead of a request.
    func asks(_ inner: [String: String]) -> [String: String] {
        guard self == .cinelounge else { return inner }
        var outgoing: [String: String] = [:]
        for (key, value) in inner {
            if Self.droppedQueries.contains(key) { continue }
            outgoing[Self.asks[key] ?? key] = value
        }
        return outgoing
    }

    private static let asks: [String: String] = [
        "einstieg": "entry",
        "weiter": "next",
        "eingabe": "input",
        "schluessel": "key",
        "adresse": "address",
        "titel": "title",
        "quelle": "source",
        "grenze": "limit",
        "sortierung": "sort",
        "richtung": "order",
    ]

    /// Query parts that do not exist at the server.
    ///
    /// `weiterleiten=false` asked the bridge to give information instead of a 302. The server in
    /// principle gives information — **never a redirect**, because a redirect carries no headers
    /// and cannot give a reason for a refusal.
    private static let droppedQueries: Set<String> = ["weiterleiten"]

    // ── Response keys ─────────────────────────────────────────────────────

    /// A response key, translated into the inner language.
    ///
    /// - Parameter pfad: The **complete** path of the key in the response, not just the key itself.
    ///   That is not convenience but necessary: ``state`` means two things at the server — the
    ///   state of a portal (`ready`/`broken`/`disabled`) and the watch state of an entry. The
    ///   bridge kept the two apart (`state` and `state`), and without the path one would have to
    ///   guess here which is meant.
    func key(path: [any CodingKey]) -> String {
        guard let last = path.last?.stringValue else { return "" }
        guard self == .cinelounge else { return last }
        if last == "state" { return Self.underPortals(path) ? "zustand" : "stand" }
        return Self.key[last] ?? last
    }

    /// Is this key in a portal of the portal list?
    ///
    /// Only there does `state` mean the state of the portal. In `items`, `hits`, `resumable` and
    /// `favorites` it is the watch state of an entry.
    ///
    /// **The path is already translated at this point** — the reader descends with the inner words,
    /// and the parent key is therefore already `portals` and no longer `portals`. It is nevertheless
    /// searched for by both: knowing only one of them would mean relying on an order that nobody
    /// promised, and the mistake would look like an empty screen.
    private static func underPortals(_ path: [any CodingKey]) -> Bool {
        path.dropLast().contains { $0.stringValue == "portals" || $0.stringValue == "portale" }
    }

    private static let key: [String: String] = [
        // Response bodies
        "portals": "portale",
        "entries": "einstiege",
        "sources": "quellen",
        "resumable": "weiterschauen",
        "hits": "treffer",
        "titles": "titelgruppen",
        "failed": "fehlgeschlagen",
        "query": "frage",
        "favorites": "favoriten",
        // An entry
        "title": "titel",
        "address": "adresse",
        "kind": "art",
        "year": "jahr",
        "description": "beschreibung",
        "image": "bild",
        "languages": "sprachen",
        "rating": "bewertung",
        "number": "nummer",
        "key": "schluessel",
        "duration_min": "dauer_minuten",
        // **`duration_s` and `dauer_s` look too alike to stand out.** The duration in seconds is in
        // every state row, and without this line it would be missing in `/state`, `/resume` and
        // `/favorites` — that is, everywhere the progress bar comes from.
        "duration_s": "dauer_s",
        "has_children": "hat_kinder",
        "image_wide": "bild_breit",
        "image_source": "bild_quelle",
        "show": "reihe",
        // A portal
        "capabilities": "faehigkeiten",
        "reason": "grund",
        "limits": "grenzen",
        "net": "netz",
        // A page
        "total": "gesamt",
        "next": "weiter",
        "note": "hinweis",
        "needs_input": "braucht_eingabe",
        "input_suggestion": "eingabe_vorschlag",
        "question": "rueckfrage",
        "preparing": "vorbereitung",
        "truncated": "abgeschnitten",
        // An entry point
        "icon": "zeichen",
        "count": "anzahl",
        "group": "gruppe",
        // A source
        "blocked": "gesperrt",
        "language": "sprache",
        // Abspielen
        "headers": "kopfzeilen",
        "proxied": "durchgereicht",
        "valid_until": "gueltig_bis",
        "subtitles": "untertitel",
        "source": "quelle",
        "switched": "gewechselt",
        // Sehstand
        "watched": "gesehen",
        "favorite": "favorit",
        "fraction": "anteil",
        "remaining_s": "rest_s",
        "changed": "geaendert",
        "series": "serie",
    ]

    /// The same way back — for everything the app **sends**.
    ///
    /// A state report carries the same words as a state row, only in the other direction. The table
    /// is turned around from ``key`` instead of written a second time: a second list would be
    /// a second opportunity to let them drift apart.
    func outgoingKey(path: [any CodingKey]) -> String {
        guard let last = path.last?.stringValue else { return "" }
        guard self == .cinelounge else { return last }
        return Self.outbound[last] ?? last
    }

    private static let outbound: [String: String] = {
        var reversed = Dictionary(uniqueKeysWithValues: key.map { ($0.value, $0.key) })
        // The app reports a watch state, never a portal state — `state` is unambiguous here, and
        // `state` does not occur.
        reversed["stand"] = "state"
        return reversed
    }()

    // ── Kopfzeilen ───────────────────────────────────────────────────────────

    /// Does this service carry a device attribute on every request?
    ///
    /// The bridge knows no persons: every device on the network sees everything. At the server the
    /// attribute is the login, and without it it answers `401 auth.required`.
    var needsMarker: Bool { self == .cinelounge }

    /// The header for the device attribute.
    static let markerHeader = "X-CL-Device"

    /// The header for the borrowed profile — **only on the TV.**
    ///
    /// A device that belongs to no person names, on every request, the profile that is currently in
    /// front of it. On the phone this header does not exist: whoever operates the app stands at the
    /// attribute and not at a parameter that a child's device could send along.
    static let profileHeader = "X-CL-Profile"
}
