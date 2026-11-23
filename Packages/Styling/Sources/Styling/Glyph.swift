/// The icon register of both devices — **one meaning per icon, one icon per
/// meaning.**
///
/// **Why it exists** (AP58, report B finding 11). Until 2026-09-26 each device kept
/// its own register (`Sinnbilder`, 87 and 92 entries). 46 icons stood in both,
/// 36 of them under other names, and the meanings crossed: `play.tv` was the programme on the
/// TV, the Live tab on the phone; `square.stack.3d.up` the season here,
/// the portals there; `back` here the globe with an arrow (a portal falls back
/// to the bridge), there the navigation chevron. And the star stood on both sides for
/// bookmarking **and** rating — exactly the double assignment that both registers were
/// supposed to prevent according to their header.
///
/// **The rule is now a check** (`GlyphTests`): No icon stands under two
/// meanings unless it is listed with a reason in ``sameSymbols``. The old registers
/// (`Sinnbilder` of both platform layers) no longer exist since AP58's final step;
/// the views name the meaning here. The one place where a device deliberately
/// shows a different icon than the meaning is the phone's tabs
/// (``Tab/exemptions``).
///
/// **Set:** Favourite is the heart, bookmark the star, rating the half star
/// (**decision 24**, 2026-09-26). **Decision 10** (2026-09-25): The channel lists
/// carry `play.tv`, Live carries the antenna with waves (`dot.radiowaves.left.and.right`) —
/// the register follows.
public enum Glyph: String, Sendable, CaseIterable {

    // MARK: The two that were confused

    /// A title or channel you like. Applies to both sources and both devices.
    case favorite = "favorit"
    /// A game you do not want to miss — explicitly not a favourite.
    case bookmark = "vormerken"
    /// A rating — **the half star** (decision 24). Until 2026-09-26 it shared
    /// the star with ``bookmark``, on both devices.
    case rating = "bewertung"

    // MARK: State of an entry

    /// Holds, is done: seen, reachable, a finished step, a chosen item.
    case done = "erledigt"
    /// Still pending: an empty item, an open step.
    case pending = "offen"
    case dotEmpty = "punktLeer"
    case dotCross = "punktKreuz"
    /// A failed step.
    case failed = "fehlgeschlagen"
    case checkbox = "kaestchen"
    case override = "haken"
    case seal = "siegel"

    // MARK: Areas and paths

    case start
    case mediaLibrary = "mediathek"
    /// A library's grid — on the phone the tab, on the TV the tile view.
    case library = "bibliothek"
    /// A collection (BoxSet).
    case isCollection = "sammlung"
    case film
    case search = "suche"
    /// Live-Fernsehen — **Entscheidung 10**.
    case live
    /// A channel list (M3U/Xtream) — **decision 10**.
    case channelList = "senderliste"
    /// A channel.
    case channels = "sender"
    /// A series as a genre of a library — stacked entries. Until 2026-09-26
    /// it carried `tv` on the phone, the icon of ``channels``.
    case series = "serie"
    /// The TV as a device that holds the one connection. **Shares `tv` with ``channels``** —
    /// see ``sameSymbols``.
    case tv = "fernseher"
    case sport
    case fetch = "abruf"
    /// The seasons of a series.
    case season = "staffel"
    case folder = "ordner"
    case list = "liste"
    case settings = "einstellungen"
    /// A playable entry: programme, trailer, clip.
    case broadcast = "sendung"
    /// A portal (a provider's web interface).
    case portal
    /// A portal falls back to the bridge.
    case portalFetchAddress = "portalAdresseHolen"
    case playback = "wiedergabe"
    case appearance = "darstellung"
    case storage = "speicher"
    case diagnose
    /// Details that demand nothing — "About" and hints. No warning icon.
    case info
    case language = "sprache"
    case toBackfill = "nachzutragen"
    case account = "konto"
    case manageAccounts = "kontenVerwalten"
    case privacy = "datenschutz"
    case license = "lizenz"
    case report = "melden"
    case sources = "quellen"

    // MARK: States

    case serverMute = "serverStumm"
    case serverMissing = "serverFehlt"
    case server
    case offline = "ohneNetz"
    case networkMissing = "netzFehlt"
    case airplaneMode = "flugmodus"
    case notPlaying = "spieltNicht"
    case hidden = "ausgeblendet"
    case isVisible = "sichtbar"
    case certificate = "zertifikat"
    case check = "pruefung"
    case login = "anmeldung"
    case setup = "einrichtung"
    case taken = "belegt"
    case unknown = "unbekannt"
    case rawStream = "rohstrom"
    case expire = "verfallen"
    case emptyCatalog = "leererBestand"
    case disruption = "stoerung"
    /// The quieter version — a disturbance that is explained and not reported.
    case warning = "warnung"
    case locked = "gesperrt"
    case parentalControls = "kindersicherung"
    case kind

    // MARK: Playback

    case play = "abspielen"
    case pause = "anhalten"
    case preamble = "vorspann"
    /// "Intro skipped · Back" after skipping by itself (AP85 binge package).
    case undoSkip = "ueberspringenZurueck"
    case subtitles = "untertitel"
    case audio = "ton"
    case aerialImage = "luftbild"
    case pictureInPicture = "bildImBild"
    case tenBack = "zehnZurueck"
    case thirtyForward = "dreissigVor"
    case skipBack = "sprungZurueck"
    case skipForward = "sprungVor"
    case fillPicture = "bildFuellen"
    case fitPicture = "bildGanz"
    case brightness = "helligkeit"
    case volume = "lautstaerke"
    case chapters = "kapitel"
    /// To the previous or next chapter (AP58 G1, A5) — in the player of both devices.
    case chapterBack = "kapitelZurueck"
    case chapterForward = "kapitelVor"
    /// Back to the running programme of a channel in time shift (AP58 G1, A1).
    case backToLive = "zurueckZuLive"
    case target = "ziel"
    /// Radio: the transmitter mast on the TV, mobile data on the phone — the same antenna.
    case funk

    // MARK: Controls

    case refresh = "auffrischen"
    case advance = "weiterschalten"
    /// To the start: reset progress, begin from the start.
    case fromStart = "vonVorn"
    case remove = "entfernen"
    case add = "hinzufuegen"
    /// Hand something outwards — share, submit.
    case share = "teilen"
    case upload = "hochladen"
    case network = "netz"
    case rate = "tempo"
    case hourglass = "sanduhr"
    case up = "hoch"
    /// Downwards, also: expand a choice in place.
    case down = "runter"
    /// To the left, also: one step back.
    case back = "zurueck"
    /// To the right, also: one step in.
    case next = "weiter"
    case upward = "nachOben"
    case downward = "nachUnten"
    case sorting = "sortierung"
    case more = "mehr"
    case close = "schliessen"
    case edit = "bearbeiten"
    case clock = "uhr"
    /// Past time: history, a channel's look-back.
    case history = "verlauf"
    case fixture = "termin"
    case appointmentMissing = "terminFehlt"
    case dayPlan = "tagesplan"
    case bell = "klingel"
    case fetchProfile = "profilHolen"
    /// Profiles waiting in iCloud during the first setup (AP88, A3).
    case cloudProfiles = "wolkenProfile"
    /// The code on the TV that the iPhone camera reads (AP88, A2).
    case codeForPhone = "codeFuersIphone"
    case merge = "zusammenlegen"
    case person
    case camera = "kamera"
    case handoff = "uebergabe"
    case downloads = "vorrat"

    // MARK: Kinds that occur only as a kind

    case homeVideo = "heimvideo"
    case music = "musik"
}

// MARK: - Symbols

extension Glyph {

    /// An icon in two versions: outlined and filled.
    ///
    /// **Filled means "holds", outlined means "does not hold".** The shape carries the state,
    /// not the colour — an indicator that only the colour carries is missing for one in ten.
    public struct Pair: Sendable, Hashable {
        public let outlined: String
        public let filled: String

        public init(_ outlined: String, _ filled: String) {
            self.outlined = outlined
            self.filled = filled
        }

        /// The icon for this state — the TV's name.
        public func forItem(_ isActive: Bool) -> String { isActive ? filled : outlined }

        /// The icon for this state — the phone's name.
        public func zu(active: Bool) -> String { active ? filled : outlined }
    }

    /// The icon of this meaning — for a pair the outlined version.
    public var name: String { character.outlined }

    /// Outlined and filled. If the meaning has only one icon, both are the same.
    public var pair: Pair { character }

    /// All SF Symbol names of this meaning, without repetition.
    public var allSymbols: [String] {
        character.outlined == character.filled
            ? [character.outlined] : [character.outlined, character.filled]
    }

    private var character: Pair {
        switch self {
        case .favorite: Pair("heart", "heart.fill")
        case .bookmark: Pair("star", "star.fill")
        case .rating: .single("star.leadinghalf.filled")
        case .done: Pair("checkmark.circle", "checkmark.circle.fill")
        case .pending: .single("circle")
        case .dotEmpty: .single("circle.dotted")
        case .dotCross: .single("xmark.circle")
        case .failed: .single("xmark.circle.fill")
        case .checkbox: Pair("square", "checkmark.square.fill")
        case .override: .single("checkmark")
        case .seal: .single("checkmark.seal.fill")
        case .start: Pair("house", "house.fill")
        case .mediaLibrary: .single("film.stack")
        case .library: Pair("square.grid.2x2", "square.grid.2x2.fill")
        case .isCollection: .single("rectangle.stack")
        case .film: .single("film")
        case .search: .single("magnifyingglass")
        case .live: .single("dot.radiowaves.left.and.right")
        case .channelList: Pair("play.tv", "play.tv.fill")
        case .channels: .single("tv")
        case .series: .single("play.rectangle.on.rectangle")
        case .tv: .single("tv")
        case .sport: .single("sportscourt")
        case .fetch: .single("popcorn.fill")
        case .season: Pair("square.stack.3d.up", "square.stack.3d.up.fill")
        case .folder: .single("folder")
        case .list: .single("list.bullet")
        case .settings: .single("gearshape")
        case .broadcast: .single("play.rectangle")
        case .portal: .single("globe")
        case .portalFetchAddress: .single("globe.badge.chevron.backward")
        case .playback: .single("play.circle")
        case .appearance: .single("paintbrush")
        case .storage: .single("internaldrive")
        case .diagnose: .single("stethoscope")
        case .info: .single("info.circle")
        case .language: .single("character.bubble")
        case .toBackfill: .single("plus.circle")
        case .account: .single("person.crop.circle")
        case .manageAccounts: .single("person.2.badge.gearshape")
        case .privacy: .single("hand.raised")
        case .license: .single("text.document")
        case .report: .single("flag")
        case .sources: .single("square.stack.3d.down.right")
        case .serverMute: .single("server.rack")
        case .serverMissing: .single("externaldrive.badge.questionmark")
        case .server: .single("externaldrive")
        case .offline: .single("wifi.slash")
        case .networkMissing: .single("wifi.exclamationmark")
        case .airplaneMode: .single("airplane")
        case .notPlaying: .single("play.slash")
        case .hidden: .single("eye.slash")
        case .isVisible: .single("eye")
        case .certificate: .single("lock.trianglebadge.exclamationmark")
        case .check: .single("exclamationmark.shield")
        case .login: .single("person.crop.circle.badge.exclamationmark")
        case .setup: .single("sparkles")
        case .taken: .single("person.2.slash")
        case .unknown: .single("questionmark.circle")
        case .rawStream: .single("waveform.badge.exclamationmark")
        case .expire: .single("clock.badge.exclamationmark")
        case .emptyCatalog: .single("tray")
        case .disruption: .single("exclamationmark.triangle.fill")
        case .warning: .single("exclamationmark.triangle")
        case .locked: .single("lock.fill")
        case .parentalControls: .single("lock.shield")
        case .kind: .single("figure.child")
        case .play: .single("play.fill")
        case .pause: .single("pause.fill")
        case .preamble: .single("forward.end.fill")
        case .undoSkip: .single("arrow.uturn.backward")
        case .subtitles: .single("captions.bubble")
        case .audio: .single("waveform")
        case .aerialImage: .single("airplayvideo")
        case .pictureInPicture: .single("pip.enter")
        case .tenBack: .single("gobackward.10")
        case .thirtyForward: .single("goforward.30")
        case .skipBack: .single("gobackward")
        case .skipForward: .single("goforward")
        case .fillPicture: .single("arrow.up.left.and.arrow.down.right")
        case .fitPicture: .single("arrow.down.right.and.arrow.up.left")
        case .brightness: .single("sun.max.fill")
        case .volume: .single("speaker.wave.2.fill")
        case .chapters: .single("list.bullet.indent")
        case .chapterBack: .single("backward.end.fill")
        case .chapterForward: .single("forward.end.fill")
        case .backToLive: .single("forward.end.alt.fill")
        case .target: .single("tv.and.hifispeaker.fill")
        case .funk: .single("antenna.radiowaves.left.and.right")
        case .refresh: .single("arrow.clockwise")
        case .advance: .single("arrow.2.squarepath")
        case .fromStart: .single("arrow.counterclockwise")
        case .remove: .single("trash")
        case .add: .single("plus")
        case .share: .single("square.and.arrow.up")
        case .upload: .single("arrow.up.circle")
        case .network: .single("network")
        case .rate: .single("speedometer")
        case .hourglass: .single("hourglass")
        case .up: .single("chevron.up")
        case .down: .single("chevron.down")
        case .back: .single("chevron.left")
        case .next: .single("chevron.right")
        case .upward: .single("arrow.up")
        case .downward: .single("arrow.down")
        case .sorting: .single("arrow.up.arrow.down")
        case .more: .single("ellipsis")
        case .close: .single("xmark")
        case .edit: .single("pencil")
        case .clock: .single("clock")
        case .history: .single("clock.arrow.circlepath")
        case .fixture: .single("calendar")
        case .appointmentMissing: .single("calendar.badge.exclamationmark")
        case .dayPlan: .single("calendar.day.timeline.left")
        case .bell: .single("bell.and.waves.left.and.right.fill")
        case .fetchProfile: .single("iphone.and.arrow.forward")
        case .cloudProfiles: .single("icloud")
        case .codeForPhone: .single("iphone.radiowaves.left.and.right")
        case .merge: .single("arrow.triangle.merge")
        case .person: .single("person.fill")
        case .camera: .single("camera")
        case .handoff: .single("arrow.up.forward.app")
        case .downloads: .single("arrow.down.circle")
        case .homeVideo: .single("video")
        case .music: .single("music.note")
        }
    }
}

extension Glyph.Pair {
    /// A single icon, the same outlined and filled.
    static func single(_ name: String) -> Self { Self(name, name) }
}

// MARK: - The open cases

extension Glyph {

    /// Several meanings that carry the same icon today — **with a reason, and every row
    /// is a question for the product owner.** Resolving them visibly changes a device.
    public struct SameSymbol: Sendable {
        public let character: String
        public let meanings: Set<Glyph>
        public let reason: String
    }

    /// The permitted double assignments. The check demands that every row holds **exactly
    /// like this** — a resolved or grown row stands out, otherwise it would cover up the
    /// next crossing.
    public static let sameSymbols: [SameSymbol] = [
        SameSymbol(
            character: "tv", meanings: [.channels, .tv],
            reason: """
                On the phone the same symbol shows the TV that holds the one connection \
                — the TV itself shows this state with `person.2.slash` (``taken``). \
                Aligning them belongs to the shared state table (report B, step 9).
                """),
        SameSymbol(
            character: "forward.end.fill", meanings: [.preamble, .chapterForward],
            reason: """
                Both jump to the end of the running section — a preamble is a \
                section like a chapter. On the TV the chapter button carried the symbol \
                before it was in the register (AP58 G1).
                """),
    ]

    /// Every icon that carries several meanings without standing exactly like this in ``sameSymbols``
    /// — **empty, otherwise the register is wrong.**
    public static func forbiddenDoubleAssignments() -> [String: Set<Glyph>] {
        var perSymbol: [String: Set<Glyph>] = [:]
        for icon in allCases {
            for name in icon.allSymbols {
                perSymbol[name, default: []].insert(icon)
            }
        }
        let isAllowed = Dictionary(
            sameSymbols.map { ($0.character, $0.meanings) }, uniquingKeysWith: { a, _ in a })
        return perSymbol.filter { character, meanings in
            meanings.count > 1 && isAllowed[character] != meanings
        }
    }
}

// MARK: - The tabs of the phone

extension Glyph {

    /// The phone's five tabs — **a platform addition, because a tab needs a filled pair.**
    /// The active tab differs in shape, not only in colour:
    /// With deuteranopia `brandLight` and `textQuiet` are at 1.02 : 1.
    public enum Tab {
        public static let start = Glyph.start.pair
        public static let library = Glyph.library.pair
        /// See ``exemptions``: the pair for the channel lists.
        public static let live = Glyph.channelList.pair
        /// See ``exemptions``: the pair for the season.
        public static let portals = Glyph.season.pair
        /// The circled magnifier — **a second icon for ``Glyph/search``**, because
        /// `magnifyingglass` has no filled counterpart. Not a crossing: The icon carries
        /// no other meaning.
        public static let search = Glyph.Pair(
            "magnifyingglass.circle", "magnifyingglass.circle.fill")

        /// In the order of the bar.
        public static let all: [Glyph.Pair] = [start, library, live, portals, search]

        /// A tab that **shows a different icon than its meaning has in the register**.
        public struct Exemption: Sendable {
            public let tab: Glyph.Pair
            /// What the tab means.
            public let meaning: Glyph
            /// Wessen Paar er zeigt.
            public let shows: Glyph
            public let reason: String
        }

        /// **The phone tab exception** (decision 24): The filled version takes precedence over the
        /// meaning. The check demands that every row really holds.
        public static let exemptions: [Exemption] = [
            Exemption(
                tab: live, meaning: .live, shows: .channelList,
                reason: """
                    The Live tab needs a filled pair, `dot.radiowaves.left.and.right` \
                    has none. Per decision 10 `play.tv` belongs to the channel lists — on the \
                    phone the "Live" tab and the "Channel lists" area carry the same \
                    symbol.
                    """),
            Exemption(
                tab: portals, meaning: .portal, shows: .season,
                reason: """
                    The Portals tab needs a filled pair, `globe` has none. On the \
                    TV the same symbol is called "Season".
                    """),
        ]
    }

    /// Every SF Symbol that the register knows — meanings and tabs.
    ///
    /// For the checks "what is drawn is in the register" of both programs.
    public static let allNames: Set<String> = Set(
        allCases.flatMap(\.allSymbols) + Tab.all.flatMap { [$0.outlined, $0.filled] })
}
