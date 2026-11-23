import Core
import Foundation

/// What the bridge sends — one to one, without interpretation.
///
/// The names are the bridge's, not the app's: anyone who puts a failure response
/// next to the source code should read the same words.
enum BridgeReply {

    struct Portals: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case portals = "portale"
            case permitted
        }

        let portals: [Portal]
        /// The portals whose titles may stay in "Continue Watching" and the favorites (AP90).
        ///
        /// A portal with a fault is missing from ``portals`` but present here: the household's
        /// rules allow it, only the technology is in the way. Its titles stay where they were,
        /// and the fault is said when one is played. Servers before AP90 do not send the field.
        let permitted: [String]?

        /// What "Continue Watching", the favorites and the Top Shelf sieve against.
        ///
        /// Without the field — an older server — this is the portal list, as before.
        var keepsTitles: Set<String> {
            Set(permitted ?? portals.map(\.id))
        }
    }

    struct Portal: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case kind = "art"
            case capabilities = "faehigkeiten"
            case state = "zustand"
            case reason = "grund"
            case description = "beschreibung"
            case limits = "grenzen"
            case network = "netz"
            case adult
        }

        let id: String
        let name: String
        let kind: String
        let capabilities: [String]
        let state: String
        let reason: String?
        /// What the portal is, in one sentence — the server supplies it, the bridge does not.
        let description: String?
        /// What the portal **cannot** do, e.g. `drm_partial`.
        ///
        /// Kept apart from ``capabilities`` because the two are different statements: a
        /// missing capability means "this control does not exist", a limit means "it
        /// exists, and it still does not always work".
        let limits: [String]?
        /// `direct` or a country code. Always `direct` today.
        let network: String?
        /// Whether the portal carries adult content.
        ///
        /// **The app hides nothing on that basis.** The server does not deliver such portals
        /// to a child device in the first place and rejects direct calls to their addresses
        /// with 403. The field is the label, not the lock — and the app must not rely on
        /// hiding being enough.
        let adult: Bool?

        /// **Two words for the same state.** The bridge wrote `ready`, the server writes
        /// `ready`; both mean that the portal can be opened. The state is not a key but a
        /// value — the ``PortalDialect`` translates keys and would not apply here.
        var isReady: Bool { state == "bereit" || state == "ready" }

        /// Can the portal do this?
        ///
        /// **The point where the app stops knowing portal names.** A seventh portal should
        /// cost no line of Swift; everything the UI needs to know about a portal is in
        /// ``capabilities``.
        func can(_ capability: PortalCapability) -> Bool {
            capability.settled(in: capabilities)
        }
    }

    /// What `/play?weiterleiten=false` answers.
    ///
    /// **The address here is already the reachable one** — the bridge decided whether it
    /// points to the host or to itself. Passing on the raw address of a portal's local proxy
    /// would give the Apple TV `127.0.0.1`, and that is the Apple TV itself.
    struct Playback: Decodable {
        let address: String
        let kind: String?
        let headers: [String: String]?
        /// Does the stream run through the bridge? Then the headers are already set there
        /// and must not be set a second time here.
        let passedThrough: Bool?

        /// Until when this address is valid — Unix time in seconds.
        ///
        /// **The difference between "expired" and "broken".** A host address is valid for
        /// five minutes, and five minutes is shorter than any interruption; without this
        /// number both cases look the same, and the only possible answer would be to
        /// re-resolve on **every** playback error — even when the host does not serve the
        /// film at all.
        ///
        /// **Optional, and that is no accident:** a bridge that does not know the field yet
        /// does not deliver it, and this response stays readable. The same rule as for every
        /// other addition to the contract.
        let validUntil: Double?

        /// The subtitle tracks the service found — **usually empty.**
        ///
        /// New on 2026-09-11, and only the server delivers them. The public broadcasters
        /// carry them throughout as WebVTT and free of charge; the portal scripts carry none.
        /// **Only WebVTT goes out:** AVPlayer does not open EBU-TT-D, and a subtitle that
        /// does not open is worse than none.
        ///
        /// **Empty means "this portal delivers none", not "not loaded yet"** — it comes
        /// from the same response as the video address. A spinner at this point would spin
        /// forever.
        let subtitles: [SubtitleTrack]?

        /// Which source actually works — and whether it was a different one than requested.
        ///
        /// Since 2026-09-16 `address` goes out with every `source`, and the server goes
        /// through the remaining sources when the requested one does not work (filmhub: the
        /// premium mirror answers 403 on every variant, seven others work). The source
        /// picker in the player should then mark the one that plays, not the one that was
        /// pressed. Both are optional — the bridge does not know them.
        let source: String?
        let switched: Bool?

        enum CodingKeys: String, CodingKey {
            case address = "adresse", kind = "art", headers = "kopfzeilen", passedThrough = "durchgereicht",
                subtitles = "untertitel", source = "quelle", switched = "gewechselt"
            case validUntil = "gueltig_bis"
        }
    }

    /// A subtitle track, as the service names it.
    struct SubtitleTrack: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case language = "sprache"
            case format
            case address = "adresse"
        }

        /// The code the portal finds — **often three letters** (`deu`), not always. Do not
        /// normalise to two letters: what is here is what the portal says; the display turns
        /// it into a language name.
        let language: String
        let format: String
        let address: String
    }

    /// What `/search` answers — **separated by portal and additionally merged.**
    ///
    /// ``match`` is the set as the bridge has always delivered it: one list per
    /// portal. ``titleGroups`` is the same set, only grouped — which of the two the app
    /// shows is its decision.
    ///
    /// **Grouping is by title and year, not by series.** "Hisvei Weprir" and "Hisvei Weprir
    /// (2023)" stay two; two episodes of the same series from two portals do too — they
    /// are not the same episode, and a list that claims so sends someone to the wrong
    /// episode.
    struct Search: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case match = "treffer"
            case titleGroups = "titelgruppen"
            case failed = "fehlgeschlagen"
        }

        let match: [String: [ContentEntryRecord]]
        /// The same hits, merged by title and year. The bridge does not deliver them —
        /// **optional, and therefore it stays readable.**
        let titleGroups: [TitleGroup]?
        /// Which portals failed in this search, and why.
        let failed: [String: String]?
    }

    /// A title and the portals that carry it.
    struct TitleGroup: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case title = "titel"
            case year = "jahr"
            case row = "reihe"
            case sources = "quellen"
        }

        let title: String
        let year: Int?
        let row: String?
        /// **The first source is the built-in one.** A `native` portal talks to a
        /// broadcaster's interface; any other kind comes from a server extension — when a title
        /// is in both, the `native` one comes first. That is a statement about origin, not about
        /// quality.
        let sources: [TitleSource]
    }

    struct TitleSource: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case portal
            case address = "adresse"
            case key = "schluessel"
            case kind = "art"
            case image = "bild"
        }

        let portal: String
        let address: String
        let key: String
        let kind: String
        let image: String?
    }

    struct Menu: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case portal
            case entries = "einstiege"
        }

        let portal: String
        let entries: [EntryPoint]
    }

    struct EntryPoint: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case character = "zeichen"
            case count = "anzahl"
            case group = "gruppe"
        }

        let id: String
        let name: String
        let character: String?
        let count: Int?
        let group: String
    }

    struct Page: Decodable {
        let portal: String
        let total: Int?
        let next: String?
        let items: [ContentEntryRecord]
        /// Why nothing came — what the portal would have shown as a message.
        ///
        /// **An empty level is not an error.** Until 2026-08-28 the bridge threw a
        /// `RuntimeError` for it, and the device showed it in red, like a defect. As a rule
        /// it was none: a category without titles on this page, a page beyond the last
        /// one. If a text is here, it is the explanation; if none, the level is simply empty.
        let hint: String?
        /// What the portal asked for — the search line of a page.
        ///
        /// A portal script expects a keyboard for this. The server has none, so the bridge
        /// says what was asked and the app asks the viewer. The answer goes back as
        /// `input`.
        let needsInput: String?
        /// What the portal's input was prefilled with — **a suggestion, not an
        /// answer.**
        ///
        /// **Optional, and therefore the old bridge stays readable** — the same rule as for
        /// every other addition to the contract. Added on 2026-09-09: a portal with a
        /// search history opens its input with the last term in it, and until then the
        /// bridge took that as the answer — it did not even ask and silently returned the
        /// hits of an old search.
        let inputSuggestion: String?
        /// What the portal wanted confirmed — **an open yes/no question.**
        ///
        /// Added on 2026-09-09 and optional like every addition to the contract.
        let followUpQuestion: String?
        /// How far the CL-Server has got with collecting a sorted level — `nil` as soon as
        /// the page is there (AP60).
        let preparation: Preparation?
        /// Whether the sorted level ended at the server's cap.
        let truncated: Bool?

        struct Preparation: Decodable {
            let done: Int

            enum CodingKeys: String, CodingKey {
                case done = "done"
            }
        }

        enum CodingKeys: String, CodingKey {
            case portal, total = "gesamt", next = "weiter", items, hint = "hinweis", followUpQuestion =
                "rueckfrage", preparation = "vorbereitung", truncated = "abgeschnitten"
            case needsInput = "braucht_eingabe"
            case inputSuggestion = "eingabe_vorschlag"
        }
    }

    struct Children: Decodable {
        let portal: String
        let items: [ContentEntryRecord]
    }

    struct ContentEntryRecord: Decodable {
        let title: String
        let address: String
        let kind: String
        let year: Int?
        let description: String?
        let image: String?
        let languages: [String]
        let rating: Double?
        let durationMinutes: Int?
        let number: Int?
        let hasChildren: Bool
        let key: String
        let state: State?
        /// Whether the image is wide (16:9) rather than tall (2:3) — if the bridge says so.
        ///
        /// **Optional, and in three states.** If the field is missing, it stays `nil`, and
        /// the app falls back to portrait — see
        /// ``Core/MediaItem/prefersWideArtwork(in:)``. A `Bool` defaulting to `false` would
        /// instead have claimed of every unchecked portal that its images are tall — a
        /// statement without basis, and in a mixed level it would have outvoted the wide
        /// images too.
        let isImageWide: Bool?
        /// The title **above** — the series this episode belongs to.
        ///
        /// **Without it a hit list is not readable** (confirmed on 2026-09-11): a search for
        /// "krimireihe" returned from the ARD media library `Episode 41: Kreidespur (S04/E05)`
        /// and `Episode 51: Was weg ist, bleibt weg (S04/E11)` — they belong to *Almwache
        /// ermittelt* and *Ruhestandsrevier*, and that was stated nowhere.
        ///
        /// In a list it belongs **above** the title, not behind it. `nil` means "belongs to
        /// nothing" (a film) or "the portal does not say"; for display both are the same. For
        /// a series it is left empty on purpose — "Krimireihe · Krimireihe" says nothing twice.
        let row: String?
        /// Where the image comes from — `portal` if the portal itself supplies it.
        let imageSource: String?
        /// The TMDb identifier including kind (`tv/1399`, `movie/603`) — only from the
        /// CL-Server, since 2026-09-29. Through it the detail view finds IMDb, Rotten
        /// Tomatoes and Metacritic values (``Core/Ratings/tmdbID``).
        let tmdbIdentifier: String?

        // The bridge writes its keys with underscores; Swift writes them in camel case.
        // Translation happens here and only here.
        enum CodingKeys: String, CodingKey {
            case title = "titel", address = "adresse", kind = "art", year = "jahr", description =
                "beschreibung",
                image = "bild", languages = "sprachen", rating = "bewertung", number = "nummer", key =
                "schluessel",
                state = "stand", row = "reihe"
            case durationMinutes = "dauer_minuten"
            case hasChildren = "hat_kinder"
            case isImageWide = "bild_breit"
            case imageSource = "bild_quelle"
            case tmdbIdentifier = "tmdb_id"
        }
    }

    struct Languages: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case portal
            case languages = "sprachen"
        }

        let portal: String
        let languages: [String]
    }

    struct State: Decodable {
        /// How far the title has been watched — **`nil` means "unknown", not "zero
        /// percent".**
        ///
        /// **The finding of 2026-09-12, confirmed on the server:** without a known duration
        /// it sends `"fraction": null`. The field here was a non-optional `Double`, and such a
        /// response broke decoding with it — not just that one state, but the whole list it
        /// was in. A title without a runtime is the rule with portal scripts, not the exception.
        let portion: Double?
        let remainingSeconds: Double?
        let positionSeconds: Double
        let seen: Bool
        let favorite: Bool
        /// The series' language choice — empty means: no preference.
        ///
        /// `decodeIfPresent`, because an older bridge does not know the field; the app
        /// should then not lose the whole list.
        let language: String

        enum CodingKeys: String, CodingKey {
            case portion = "anteil", seen = "gesehen", favorite = "favorit", language = "sprache"
            case remainingSeconds = "rest_s"
            case positionSeconds = "position_s"
        }

        /// Written by hand because a custom decoder alongside it displaces the supplied
        /// version — and the test suite builds states.
        init(
            portion: Double?,
            remainingSeconds: Double?,
            positionSeconds: Double,
            seen: Bool,
            favorite: Bool,
            language: String = ""
        ) {
            self.portion = portion
            self.remainingSeconds = remainingSeconds
            self.positionSeconds = positionSeconds
            self.seen = seen
            self.favorite = favorite
            self.language = language
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            portion = try values.decodeIfPresent(Double.self, forKey: .portion)
            remainingSeconds = try values.decodeIfPresent(Double.self, forKey: .remainingSeconds)
            positionSeconds = try values.decode(Double.self, forKey: .positionSeconds)
            seen = try values.decode(Bool.self, forKey: .seen)
            favorite = try values.decode(Bool.self, forKey: .favorite)
            language = try values.decodeIfPresent(String.self, forKey: .language) ?? ""
        }
    }

    struct Sources: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case portal
            case sources = "quellen"
        }

        let portal: String
        let sources: [Source]
    }

    struct Source: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case language = "sprache"
            case locked = "gesperrt"
            case reason = "grund"
        }

        let id: String
        let name: String
        let language: String?
        let locked: Bool
        let reason: String?
    }

    /// An entry from `state.sqlite` — the same row for "Continue Watching" and favorites.
    struct ProgressRow: Decodable {
        let key: String
        let portal: String
        let title: String
        let year: Int?
        let address: String
        /// Optional, because an entry from before these columns does not have them — the
        /// state survives an extension instead of being deleted.
        let kind: String?
        let image: String?
        let positionSeconds: Double
        let durationSeconds: Double
        let seen: Bool
        let favorite: Bool
        /// **`nil` means "unknown"** — the same finding as for ``State/portion``.
        let portion: Double?
        let remainingSeconds: Double?
        /// When last watched, in seconds since 1970 — for the Top Shelf, which mixes with
        /// Jellyfin and IPTV by "last watched". The old bridge does not know the field.
        let changed: Double?
        /// The series of an episode — the app identifier of its detail page, since
        /// 2026-10-01. Older entries have none; "Details" then shows the episode as before.
        let series: String?

        enum CodingKeys: String, CodingKey {
            case key = "schluessel", portal, title = "titel", year = "jahr", address = "adresse", kind =
                "art", image = "bild",
                seen = "gesehen", favorite = "favorit", portion = "anteil"
            case changed = "geaendert", series = "serie"
            case positionSeconds = "position_s"
            case durationSeconds = "dauer_s"
            case remainingSeconds = "rest_s"
        }
    }

    struct ContinueWatching: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case continueWatching = "weiterschauen"
        }

        let continueWatching: [ProgressRow]
    }

    struct Favorites: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case favorites = "favoriten"
        }

        let favorites: [ProgressRow]
    }
}

/// What goes to `POST /state`.
///
/// **The empty fields are the core of the matter.** `JSONEncoder` omits them, and
/// the bridge leaves in place whatever is not named. That way the player can report
/// its position every ten seconds without also writing the watched mark or the
/// favorite mark — a call that did would silently empty the favorites.
struct ProgressReport: Encodable, Sendable {
    let portal: String
    let key: String
    let address: String
    var title: String?
    var year: Int?
    /// What the entry is and what it looks like — **both belong in the state**
    /// (viewer finding 2026-08-28: "with favorites you do not see the poster content, and on
    /// opening it says 'Der Server meldet eine Stoerung'").
    ///
    /// Favorites and Continue Watching are answered from the state and not from the
    /// portal — a portal script has no lookup for a single entry. What does not come along here
    /// is gone there for good: without `kind` every entry became an episode, and the
    /// detail page of a series then asked for an episode that does not exist.
    var kind: String?
    var image: String?
    var positionSeconds: Double?
    var durationSeconds: Double?
    var seen: Bool?
    var favorite: Bool?
    /// How this series should be watched — "(DE)", "(JPN) Sub: (EN)".
    ///
    /// Empty is a choice and not "nothing reported": it resets the preference. That is
    /// why the field is only sent when it is meant — a `nil` lets the bridge keep the
    /// existing choice, just like position and favorite mark.
    var language: String?
    /// The identifier of the series this episode belongs to — see
    /// ``PortalSource/children(of:)``.
    var series: String?

    enum CodingKeys: String, CodingKey {
        case portal, key = "schluessel", address = "adresse", title = "titel", year = "jahr", kind = "art",
            image = "bild",
            seen = "gesehen", favorite = "favorit", language = "sprache", series = "serie"
        case positionSeconds = "position_s"
        case durationSeconds = "dauer_s"
    }
}

/// The identifier of a portal entry — three pieces of information in one string.
///
/// The ``ContentSource`` contract prescribes a `String` as identifier, but a portal
/// entry needs three things that must not fall apart:
///
/// - **which portal** — the bridge serves any number of them,
/// - **the key** (`portal : title : year`) for the state,
/// - **the address** for the next step at the portal.
///
/// They stand side by side because they **last for different lengths of time**: the
/// address changes as soon as a page is rebuilt — the key does not. Anyone who put
/// both into one would lose "Continue Watching" for the whole catalog as soon as a
/// portal changes its address scheme (trap 2 of the design).
///
/// The separator is `|`. It cannot occur in any of the three parts: the portal
/// identifier is a folder name, the key consists of lowercase letters, digits and
/// hyphens, and the address is percent-encoded.
public struct PortalItemID: Sendable, Equatable {

    static let separator: Character = "|"

    public let portal: String
    public let key: String
    public let address: String

    public init(portal: String, key: String, address: String) {
        self.portal = portal
        self.key = key
        self.address = address
    }

    public var identifier: String { "\(portal)|\(key)|\(address)" }

    /// Splits an identifier — the address may itself contain `|` should a portal ever
    /// emit one, hence only two cuts.
    public init?(_ identifier: String) {
        let split = identifier.split(
            separator: Self.separator, maxSplits: 2, omittingEmptySubsequences: false)
        guard split.count == 3, !split[0].isEmpty else { return nil }
        self.portal = String(split[0])
        self.key = String(split[1])
        self.address = String(split[2])
    }
}

/// A level of a portal — the entries and what the portal says about them.
///
/// **The two additions are the reason this type exists.** Before, a level returned
/// only `[MediaItem]`, and with that "empty" could not be told from "broken": the
/// bridge had to throw an error so that anything was shown on the device at all. But
/// an empty folder is a normal case for a portal, and a red error for it is a false
/// statement.
public struct PortalTier: Sendable, Equatable {

    public let items: [MediaItem]
    /// Warum nichts kam — „Nothing found" des Ablesers, im Klartext.
    public let hint: String?
    /// What the portal asked for. If it is set, an input field belongs at this spot: the
    /// portal expects a keyboard here.
    public let query: String?

    /// What may already be in the input field — **the suggestion for the ``query``.**
    ///
    /// **It is not an answer, and that is the whole difference.** Until 2026-09-09 a
    /// portal's prefilled input counted as answered: a portal with a search history fills
    /// it with the last term, the bridge said nothing, and "New Search"
    /// delivered the hits of a foreign, old search. Now the question comes — and next to
    /// it what the portal had prefilled.
    ///
    /// `nil` for every bridge that does not know the field yet.
    public let suggestion: String?

    /// What the portal wanted confirmed — **a question, not information.**
    ///
    /// **Finding of 2026-09-09:** "Clear Search History" at one portal returns
    /// `items: []` and the sentence "Confirm: Are you sure you want to clear the search
    /// history?". Without this field that cannot be told from an empty level, and the
    /// device showed "Nothing here" above an unanswered question.
    ///
    /// **It cannot be answered yet.** The way back is missing — a parameter that, like
    /// `input`, reaches from the app all the way to the bridge's `Portal.list`. Until
    /// then the bridge says "no" and at least names the question.
    public let followUpQuestion: String?

    /// How many entries there are in total — `nil` where the portal does not say.
    ///
    /// **Information, not a calculation aid.** It is not in every response: measured on
    /// 2026-09-06, Animehub ("Alle Serien" 2,463) and Serieshub ("Alle Serien" 10,869)
    /// give it, the ARD media library at none of its nine entry points. Anyone who made
    /// "zero" of its absence would write "0 titles" above fifteen visible ones.
    public let total: Int?

    /// The marker of the next page — `nil` means: **that was all.**
    ///
    /// **Opaque, and that is the point.** What is in it belongs to the portal script; the
    /// bridge passes it through, and this app returns it unchanged. Measured on 2026-09-06,
    /// at the ARD it is a page number that **jumps** (page 1 names 3, page 3 names 6) —
    /// anyone who computed "next = current + 1" from it would skip entries.
    ///
    /// **Only the ARD paginates at all**: its nine entry points deliver 2 to 25 titles
    /// per page and each names a marker; Animehub and Serieshub deliver everything at
    /// once and name none. Without this path only **fifteen films** were reachable at
    /// the ARD and the rest not at all.
    public let next: String?

    /// How many entries the server has already collected for a sorted level — set
    /// **while it is not finished yet**, and then without `items`.
    ///
    /// **Why it exists** (AP60, 2026-09-30): sorting runs over all pages, not over the
    /// loaded one (product requirement). A fresh page takes 4–5 s at the provider,
    /// "Anime Japan auf Deutsch" has 38 of them; no request waits that long. The server
    /// collects in the background, and here it says how far it is.
    public let preparedCount: Int?

    /// Whether the sorted level ended at the server's cap (1,500 entries).
    public let truncated: Bool

    /// - Parameter vorschlag: **At the end and with a default**, so that every caller
    ///   that does not know it compiles unchanged — the same rule as for every other
    ///   addition.
    public init(
        items: [MediaItem], hint: String? = nil, query: String? = nil,
        total: Int? = nil, next: String? = nil, suggestion: String? = nil,
        followUpQuestion: String? = nil, preparedCount: Int? = nil, truncated: Bool = false
    ) {
        self.items = items
        self.hint = hint
        self.query = query
        self.total = total
        self.next = next
        self.suggestion = suggestion
        self.followUpQuestion = followUpQuestion
        self.preparedCount = preparedCount
        self.truncated = truncated
    }
}

/// A host of a title — **one row from `/sources`.**
///
/// **It is not what its name promises**, and that is why this type exists: measured
/// on the bridge on 2026-09-06, `/sources` for Animehub returns twelve rows for **one**
/// episode — four hosts (HOSTA, Hosth, Klenvauk, Ditstokrais) times three language
/// versions ((DE), (JPN) Sub: (EN), (JPN) Sub: (DE)). At the ARD there are ten rows
/// that are **not hosts at all** but resolution levels: "HD 1080p", "SD 540p",
/// "Auto", each once more with audio description.
///
/// A flat list of that shows "HOSTA" four times one under another. What the viewer
/// chooses are **two to three things** hidden in the cross product — they are
/// separated where they are shown, not here.
public struct PortalFileHost: Sendable, Equatable, Identifiable {

    /// The identifier that `/play?source=` expects.
    public let id: String
    public let name: String
    /// The language version as the portal writes it — "(DE)", "(JPN) Sub: (EN)".
    public let language: String?
    public let locked: Bool
    /// Why blocked. **The bridge's sentence, verbatim** — "does not work" is not
    /// information, the service's own reason is.
    public let reason: String?

    public init(
        id: String, name: String, language: String? = nil, locked: Bool = false,
        reason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.locked = locked
        self.reason = reason
    }
}

/// The identifier of a portal library: one entry point of a portal.
///
/// An entry point — "Neue Folgen", "Alle Serien" — is for the library view the same
/// as a section at the provider: a ``Library``. That way the existing view shows
/// portals without a line of its own display code.
public struct PortalLibraryID: Sendable, Equatable {

    public let portal: String
    public let entry: String
    /// The search term this level answers — empty for almost every one.
    ///
    /// **It belongs in the identifier and not next to it**, because the identifier is a
    /// level's identity and more than one place uses it: the folder list fetches the
    /// level itself, the title grid fetches it a second time via
    /// ``PortalSource/items(in:filter:)``. If the term were next to it, the grid would
    /// fetch the **unsearched** level — at Serieshub that means four found series in
    /// the list and an empty grid next to it.
    public let input: String

    public init(portal: String, entry: String, input: String = "") {
        self.portal = portal
        self.entry = entry
        self.input = input
    }

    /// `portal | search term | entry point` — the entry point last, and that is the point.
    ///
    /// It is the only part that may itself contain a bar: it is an address of the
    /// portal, and what a portal script writes into it is decided by nobody here. The search
    /// term is percent-encoded and afterwards safely carries none; what is behind the
    /// second bar is therefore the entry point, undivided.
    public var identifier: String {
        "\(portal)|\(Self.encoded(input))|\(entry)"
    }

    public init?(_ identifier: String) {
        let split = identifier.split(
            separator: PortalItemID.separator, maxSplits: 2, omittingEmptySubsequences: false)
        guard split.count == 3, !split[0].isEmpty else { return nil }
        self.portal = String(split[0])
        self.input = String(split[1]).removingPercentEncoding ?? ""
        self.entry = String(split[2])
    }

    /// Percent-encoded, and explicitly without `|` in the allowed set.
    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}

extension BridgeReply.ContentEntryRecord {

    /// An entry of the bridge as a ``MediaItem``.
    ///
    /// **The image address is in `posterID`, not built but passed through.** The same
    /// agreement as for the provider catalog: Jellyfin builds addresses from
    /// identifier, width and tag — a portal delivers finished, foreign addresses.
    func asMediaItem(portal: String) -> MediaItem {
        let identifier = PortalItemID(portal: portal, key: key, address: address).identifier

        var frames = Artwork()
        frames.posterID = image
        frames.isWide = isImageWide

        var progress: PlaybackProgress?
        if let state, state.positionSeconds > 0 || state.seen {
            // Without a known duration the bar carries no information — then the position is
            // shown, and the duration as whatever the entry states.
            let duration =
                (durationMinutes.map { Double($0) * 60 })
                ?? Self.durationFromFraction(state)
            progress = PlaybackProgress(
                position: state.positionSeconds, duration: duration, isWatched: state.seen)
        }

        let mediaKind = Self.kindFromType(kind)

        var piece = MediaItem(
            id: identifier,
            kind: mediaKind,
            title: title,
            overview: Self.subtitles(description, forTitle: title),
            year: year,
            runtime: durationMinutes.map { Double($0) * 60 },
            ratings: Ratings(community: rating, tmdbID: tmdbIdentifier),
            artwork: frames,
            progress: progress,
            isFavorite: state?.favorite ?? false,
            source: Self.fileDetails(forItem: mediaKind)
        )
        // **The series above the title** (stage 4, 2026-09-12). In the contract
        // `parentTitle` means "for episodes the series name, otherwise empty" — and that is
        // exactly `show`. Hence no new field: ``HomeView``, ``EpisodeCard``,
        // ``FavoritesModel`` and the detail handoff have long read it, and a second field
        // next to it would mean convincing each of these places individually.
        //
        // **Empty is not the same as `nil`, and both should be `nil` here.** For a series
        // the server sends the series name empty on purpose — "Krimireihe · Krimireihe" says
        // nothing twice —, and an empty string would be a line without content for the
        // display instead of no line.
        piece.parentTitle = row?.isEmpty == false ? row : nil
        // **The languages for the poster corner** (AP84). The field was in the contract and
        // was read, but never arrived at the title. Empty stays `nil`: unknown, not German.
        piece.languages = languages.isEmpty ? nil : languages
        // **The number was there and was thrown away.** The bridge sends it with every
        // episode and every season (`number`); here it was dropped until 2026-09-06. On the
        // phone more hung on it than it seems: the detail page bundles its episodes **by
        // season number**, and without numbers there was not a single group — "Bloufeit" opened
        // with image, text and rating and **without one episode**.
        //
        // **The season number is set by ``PortalSource/episodes(of:)``**, not by this
        // spot: an episode does not know from its own response which season it is in — only
        // whoever fetched it knows.
        switch mediaKind {
        case .episode: piece.episodeNumber = number
        case .season: piece.seasonNumber = number
        default: break
        }
        return piece
    }

    /// What the player has to know about the file before it even asks.
    ///
    /// **Without this information nothing plays, and silently** (viewer finding 2026-08-28
    /// on the device: "videos still cannot be played"). ``startPlayback`` begins with
    ///
    /// ```swift
    /// guard let media = full.source else { … return }
    /// ```
    ///
    /// and turns back there: no error on screen, no request to the bridge, nothing. In
    /// the bridge's log that was exactly what showed — the TV fetched lists, seasons and
    /// episodes and afterwards made **not a single** `/sources` request. So the error
    /// sat before playback and not in it, and that is why every repair to the resolution
    /// chain changed nothing.
    ///
    /// Jellyfin gets this information from the media server, the provider catalog builds
    /// it from `get_vod_info`. A portal has neither source — but it knows what arrives in
    /// the end: **a finished file that the player takes unchanged.** That is exactly what
    /// is here and not a word more; none of it is guessed.
    ///
    /// The container is only certain after resolving. `mp4` is what was measured —
    /// Serieshub and Animehub answer throughout with `video/mp4` — and it leads the
    /// engine selector down the same path as `hls`: the special handling there applies
    /// only to `mkv` and `ts`.
    ///
    /// Folders, series, seasons and separator rows get **nothing**. They are not
    /// playable, and a statement on them would claim they were.
    static func fileDetails(forItem kind: MediaItem.Kind) -> MediaSource? {
        guard kind == .episode || kind == .movie else { return nil }
        return MediaSource(container: .mp4, supportsDirectPlay: true)
    }

    /// A description that only repeats the title is none.
    ///
    /// **Viewer finding 2026-08-27:** at one portal `description` consistently contains the
    /// same text as `title`. In the folder list it therefore appeared twice one under the
    /// other, and because the detail page inherits the same field, a third time there.
    ///
    /// **Fixed here and not in the view**, although it would work there too: every view
    /// that shows the text would have to run the same comparison again — and the next
    /// one added would not. What is no information does not get into the entry at all.
    ///
    /// The comparison ignores margins and letter case: portals deliver the same title
    /// sometimes with trailing spaces, sometimes in capitals.
    static func subtitles(_ description: String?, forTitle title: String) -> String? {
        guard let description else { return nil }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.localizedCaseInsensitiveCompare(name) != .orderedSame else { return nil }
        return text
    }

    /// The kind of an entry — **in both languages.**
    ///
    /// **The finding of 2026-09-12, and it nearly cost every folder list.** The
    /// ``PortalDialect`` translates keys; but the kind is a **value**. The bridge writes
    /// `folder`, the server `folder` — and without the second line every server folder
    /// fell into the `default` branch and became a series. For "Beliebte Serien" that
    /// meant thirty genres as posters, exactly the viewer finding of 2026-08-27 that
    /// `kindFromType` had fixed once.
    ///
    /// It was noticed because the same test series runs against **both** services. The
    /// same type of error is in ``BridgeReply/Portal/isReady`` (`ready`/`ready`)
    /// and in ``PortalCapability`` (`seasons`/`seasons`) — where a value carries a
    /// statement, it has to be read bilingually.
    ///
    /// `default: .series` stays the guess for the unknown: it shows too much (a detail
    /// page) instead of sending a tap into the void.
    /// Back-calculate the duration from the share — **only if both yield something.**
    ///
    /// Without a known duration the bar carries no information; then the position is
    /// shown, and the duration as whatever the entry states. A `nil` share and a share of
    /// zero are the same here: neither can be divided.
    static func durationFromFraction(_ state: BridgeReply.State) -> Double {
        guard let portion = state.portion, portion > 0 else { return 0 }
        return state.positionSeconds / portion
    }

    static func kindFromType(_ type: String) -> MediaItem.Kind {
        switch type {
        case "film", "movie": .movie
        case "staffel", "season": .season
        case "folge", "episode": .episode
        // **A folder is not a title**, and the bridge now says so by itself: it derives the
        // kind from the target function, not from the view the portal suggests.
        // "Beliebte Serien" at Serieshub are thirty genres.
        case "ordner", "folder": .folder
        case "trenner", "separator": .separator
        // **A film series is a collection** (2026-11-08, Filmhub `kollektionen`): poster,
        // description, below it the parts — like a collection on the media server. Until
        // then it arrived as a folder and appeared as a text line in a list.
        case "sammlung", "collection": .collection
        default: .series
        }
    }

    /// The reverse direction — for the state, which stores the kind along with it.
    ///
    /// **Deliberately next to ``kindFromType`` and not elsewhere:** two translations of the
    /// same table drift apart as soon as a kind is added. Whoever adds something here
    /// sees the reverse direction at the same glance.
    ///
    /// **And it needs the dialect** (2026-09-12): a kind is a value, and the writer does
    /// not translate values. A `episode` sent to the server would be the same to it as a
    /// word that does not exist.
    static func kindName(forItem kind: MediaItem.Kind, in dialect: PortalDialect) -> String? {
        switch (kind, dialect) {
        case (.movie, .bridge): "film"
        case (.movie, .cinelounge): "movie"
        case (.season, .bridge): "staffel"
        case (.season, .cinelounge): "season"
        case (.episode, .bridge): "folge"
        case (.episode, .cinelounge): "episode"
        case (.folder, .bridge): "ordner"
        case (.folder, .cinelounge): "folder"
        case (.separator, .bridge): "trenner"
        case (.separator, .cinelounge): "separator"
        case (.series, .bridge): "serie"
        case (.series, .cinelounge): "series"
        case (.collection, .bridge): "sammlung"
        case (.collection, .cinelounge): "collection"
        // Everything else belongs to no portal — there is no name for it, and an invented
        // statement would be worse than none.
        default: nil
        }
    }
}

extension BridgeReply.ProgressRow {

    /// **The kind comes from the state, not from an assumption.**
    ///
    /// Here `.episode` was hard-coded — for every entry. But "Haubla" is a series, and the
    /// detail page then asked for an episode that does not exist: "Der Server meldet eine
    /// Stoerung", while the same title opened flawlessly through the portal (viewer
    /// finding 2026-08-28).
    ///
    /// If the information is missing (old entries from before this column), it stays
    /// `.episode` — that is the most common kind in the state, and an old entry should
    /// not vanish just because it is incomplete.
    func asMediaItem() -> MediaItem {
        let identifier = PortalItemID(portal: portal, key: key, address: address).identifier
        let mediaKind =
            kind.flatMap { $0.isEmpty ? nil : BridgeReply.ContentEntryRecord.kindFromType($0) } ?? .episode

        var frames = Artwork()
        frames.posterID = image?.isEmpty == false ? image : nil

        var item = MediaItem(
            id: identifier,
            kind: mediaKind,
            title: title,
            year: year,
            runtime: durationSeconds > 0 ? durationSeconds : nil,
            artwork: frames,
            progress: PlaybackProgress(
                position: positionSeconds, duration: durationSeconds, isWatched: seen),
            isFavorite: favorite,
            source: BridgeReply.ContentEntryRecord.fileDetails(forItem: mediaKind)
        )
        item.lastWatched = changed.map(Date.init(timeIntervalSince1970:))
        item.seriesID = series.flatMap { $0.isEmpty ? nil : $0 }
        return item
    }
}

/// The headings of the groups a server may put into a level as separators (AP77).
///
/// The same words as the server sends, because the separators **in** a level come from
/// there and the separators at the root from here — two spellings for the same group
/// would be the difference nobody can explain.
public enum PortalGroups {
    public static let recentlyUsed = "Zuletzt genutzt"
    public static let all = "Alle"
    public static let myAreas = "Meine Bereiche"
    public static let tools = "Werkzeuge"

    /// The catalog key for a group heading, or `nil` for any other separator.
    ///
    /// **Recognized by its wording**, because the headings arrive in German from both sides:
    /// from here at the root and from the server inside a level. Shown verbatim, "Werkzeuge"
    /// stood above "Search" in the English interface (screenshot run 2026-11-15).
    public static func wordingKey(for title: String) -> String? {
        switch title {
        case recentlyUsed: "portal.group.recent"
        case all: "portal.group.all"
        case myAreas: "portal.group.mine"
        case tools: "portal.group.tools"
        default: nil
        }
    }
}

extension PortalTier {
    /// This level extended by the next page — duplicates out, the marker of the following
    /// page.
    ///
    /// **For the folder list and the search hits on the TV** (AP77, 2026-10-11): the
    /// poster grid has fetched following pages since AP60, the other two views did not —
    /// in some portals the categories are folder lists, and AP76 did not arrive there.
    public func using(nextPage: PortalTier) -> PortalTier {
        var seenIDs = Set(items.map(\.id))
        let fresh = nextPage.items.filter { seenIDs.insert($0.id).inserted }
        return PortalTier(
            items: items + fresh, hint: hint, query: query,
            total: nextPage.total ?? total, next: nextPage.next, suggestion: suggestion,
            followUpQuestion: followUpQuestion, preparedCount: preparedCount,
            truncated: truncated || nextPage.truncated)
    }
}
